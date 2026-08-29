import Dispatch
import Foundation
import CLibProc

/// The daemon's authoritative state. v0.3 keeps the four roles the literature
/// separates: PredictionEngine (forecast), PageHinkley inside it (regime
/// reset), PressureGauge (corroboration gate), LeakDetector (per-app trend +
/// personalized baselines), and UsageModel (disruption-aware ranking).
/// Mutable state is serialized on `queue`; the LLM call runs on
/// `escalationQueue` so it can never stall sampling or the socket.
public final class Engine {
    public let queue = DispatchQueue(label: "memagent.engine")
    private let escalationQueue = DispatchQueue(label: "memagent.escalation")
    let db: Database
    let predictor = PredictionEngine()
    var gauge = PressureGauge()
    let leaks = LeakDetector()
    let usage = UsageModel()
    let idleTracker = IdleTracker()
    let executor = Executor()
    let chrome = ChromeBridge()
    let claude = ClaudeCLI()
    let audit = Audit(url: Paths.auditLog)
    let startedAt = Date()

    private var latestProcesses: [ProcessSample] = []
    private var swapInEwma = EWMA(halfLife: 120)
    private var lastSwapIns: (t: Double, pages: UInt64)?
    private var totalBytes: Double = 0
    private let ncpu = ProcessInfo.processInfo.processorCount

    // Phase D state (on queue).
    private var pending: [String: ActionVerdict] = [:]
    private var rateLimiter = RateLimiter()
    private var escalationInFlight = false
    private let dockerAvailable = Executor.dockerAvailable()
    private var executedActionTimes: [Double] = []          // hourly budget
    private var lastActionByTarget: [String: Double] = [:]  // per-app cooldown

    private var timers: [DispatchSourceTimer] = []
    private var pressureSource: PressureSource?

    public static let systemInterval = 10.0
    public static let processInterval = 30.0
    public static let frontmostInterval = 15.0
    public static let persistInterval = 300.0
    public static let processTopN = 40
    public static let detectorFloorBytes: UInt64 = 100 * 1_048_576
    public static let detectorMaxProcesses = 150
    /// Autonomous escalation fires when P(critical within 15 min) exceeds this.
    public static let escalationProbability = 0.8
    /// Falcon-style disruption budget.
    public static let maxActionsPerHour = 4
    public static let perTargetCooldown = 1800.0
    /// Acclaim: an action type re-faulting >25% of the time disables itself.
    public static let refaultDisableRate = 0.25

    public init(db: Database) {
        self.db = db
        self.totalBytes = Double((try? SystemStats.totalMemory()) ?? 0)
        loadPersistedState()
    }

    // MARK: - Persistence of learned state

    private func loadPersistedState() {
        if let json = try? db.loadBlob(key: "avail_histogram"),
           let hist = try? JSON.decoder.decode(DecayedHistogram.self, from: Data(json.utf8)) {
            predictor.availHistogram = hist
        }
        if let json = try? db.loadBlob(key: "app_baselines") {
            leaks.loadBaselines(json: json)
        }
        if let json = try? db.loadBlob(key: "usage_model"),
           let model = try? JSON.decoder.decode(UsageModel.self, from: Data(json.utf8)) {
            usage.apps = model.apps
            usage.ppmCounts = model.ppmCounts
            usage.ppmHits = model.ppmHits
            usage.ppmTotals = model.ppmTotals
        }
        if let json = try? db.loadBlob(key: "pressure_gauge"),
           let g = try? JSON.decoder.decode(PressureGauge.self, from: Data(json.utf8)) {
            gauge = g
        }
    }

    private func persistState() {
        func save<T: Encodable>(_ key: String, _ value: T) {
            if let data = try? JSON.encoder.encode(value),
               let json = String(data: data, encoding: .utf8) {
                try? db.saveBlob(key: key, json: json)
            }
        }
        save("avail_histogram", predictor.availHistogram)
        if let json = try? leaks.baselinesJSON() {
            try? db.saveBlob(key: "app_baselines", json: json)
        }
        save("usage_model", usage)
        save("pressure_gauge", gauge)
    }

    // MARK: - Lifecycle

    public func start() {
        schedule(interval: Self.systemInterval) { [weak self] in self?.sampleSystem() }
        schedule(interval: Self.processInterval) { [weak self] in self?.sampleProcesses() }
        schedule(interval: Self.frontmostInterval) { [weak self] in self?.sampleFrontmost() }
        schedule(interval: Self.persistInterval) { [weak self] in self?.persistState() }
        schedule(interval: 30) { [weak self] in
            guard let self else { return }
            self.executor.revertDue(pressureNormal: SystemStats.pressureLevel() == 1,
                                    audit: self.audit)
        }
        schedule(interval: 6 * 3600) { [weak self] in try? self?.db.prune(olderThanDays: 7) }
        schedule(interval: 3600) { [weak self] in self?.selfCheck() }
        pressureSource = PressureSource(queue: queue) { [weak self] level in
            guard let self else { return }
            self.log("kernel pressure transition: \(level)")
            try? self.db.insertEvent(kind: "pressure_transition", json: "{\"level\":\"\(level)\"}")
            if level != "normal" {
                self.maybeEscalate(trigger: "pressure_\(level)")
            }
        }
        queue.async {
            self.sampleSystem()
            self.sampleProcesses()
        }
    }

    public func shutdown() {
        queue.sync {
            executor.revertAll(audit: audit)
            persistState()
        }
    }

    private func schedule(interval: Double, _ block: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler(handler: block)
        timer.resume()
        timers.append(timer)
    }

    // MARK: - Sampling (on queue)

    private func sampleSystem() {
        do {
            let snap = try SystemStats.sample()
            try db.insert(system: snap)
            gauge.observe(snap, ncpu: ncpu)
            predictor.observe(t: snap.ts, avail: Double(snap.availBytes))

            if let last = lastSwapIns, snap.ts > last.t {
                let rate = Double(snap.swapIns &- min(snap.swapIns, last.pages)) / (snap.ts - last.t)
                swapInEwma.add(rate, at: snap.ts)
            }
            lastSwapIns = (snap.ts, snap.swapIns)

            // Predictive trigger, gated by corroborating measured pain
            // (a forecast without pain only warrants cheap suggestions).
            let p = prediction()
            if p.pPressure15min >= Self.escalationProbability, gauge.avg10 > 0.1 {
                maybeEscalate(trigger: String(format: "p15_%.0f%%_thrash_%.2f",
                                              p.pPressure15min * 100, gauge.avg10))
            }
        } catch {
            log("system sample failed: \(error)")
        }
    }

    private func sampleProcesses() {
        let sweep = ProcessStats.sweep()
        latestProcesses = sweep.samples
        idleTracker.ingest(sweep.samples)
        let sorted = sweep.samples.sorted { $0.footprintBytes > $1.footprintBytes }
        do {
            try db.insert(processes: Array(sorted.prefix(Self.processTopN)))
        } catch {
            log("process insert failed: \(error)")
        }
        let watched = sorted.lazy
            .filter { $0.footprintBytes >= Self.detectorFloorBytes }
            .prefix(Self.detectorMaxProcesses)
        for leak in leaks.ingest(Array(watched)) {
            log("leak: \(leak.name) (pid \(leak.pid)) +\(String(format: "%.0f", leak.slopeMbPerHour)) MB/h, \(formatBytes(leak.footprintBytes)) vs ceiling \(formatBytes(leak.ceilingBytes))")
        }
    }

    private func sampleFrontmost() {
        // lsappinfo is a subprocess — run it off-queue, apply on-queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let name = Frontmost.appName()
            let now = Date().timeIntervalSince1970
            self?.queue.async {
                guard let self else { return }
                let previous = self.usage.currentApp
                self.usage.observeFrontmost(name, at: now)
                if let name, name != previous {
                    try? self.db.insertUsage(ts: now, name: name, event: "frontmost")
                    // Re-fault check: user returned to something we suspended.
                    if let suspension = self.executor.suspensions.values.first(where: { $0.name == name }) {
                        self.executor.revertNow(pid: suspension.pid,
                                                reason: "user returned to app (re-fault)",
                                                audit: self.audit)
                        try? self.db.markRefault(action: "sigstop_process", target: name,
                                                 since: suspension.startedAt - 1)
                        self.log("re-fault: \(name) reactivated while suspended — reverted early")
                    }
                }
            }
        }
    }

    private func selfCheck() {
        var ru = memagent_rusage()
        if memagent_pid_rusage(getpid(), &ru) == 0, ru.phys_footprint > 50 * 1_048_576 {
            log("WARNING: daemon RSS \(formatBytes(ru.phys_footprint)) exceeds 50 MB budget")
        }
    }

    // MARK: - Reads (call on queue)

    public func currentState() throws -> (SystemSnapshot, DaemonInfo) {
        let snap = try SystemStats.sample()
        var ru = memagent_rusage()
        _ = memagent_pid_rusage(getpid(), &ru)
        let info = DaemonInfo(
            version: memAgentVersion,
            pid: getpid(),
            uptimeSeconds: Date().timeIntervalSince(startedAt),
            rssBytes: ru.phys_footprint,
            suspensions: executor.suspensions.count,
            escalationHealth: rateLimiter.health(now: Date().timeIntervalSince1970),
            thrashIndex: gauge.avg10,
            thrashLabel: gauge.label)
        return (snap, info)
    }

    public func topConsumers(n: Int) -> [ConsumerGroup] {
        Array(ProcessStats.group(latestProcesses).prefix(n))
    }

    public func prediction() -> Prediction {
        let swapRate = swapInEwma.value ?? 0
        var drivers: [String] = []
        for leak in leaks.active().prefix(3) {
            drivers.append("\(leak.name) (pid \(leak.pid)) leaking \(String(format: "%.0f", leak.slopeMbPerHour)) MB/h above its learned ceiling")
        }
        if gauge.avg10 > 0.1 {
            drivers.append("thrash index \(String(format: "%.2f", gauge.avg10)) (\(gauge.label))")
        }
        if swapRate > 100 {
            drivers.append(String(format: "swap-in rate %.0f pages/s", swapRate))
        }
        if drivers.isEmpty, let top = topConsumers(n: 1).first {
            drivers.append("largest consumer: \(top.name) at \(formatBytes(top.footprintBytes))")
        }
        return predictor.predict(totalBytes: totalBytes,
                                 swapInRatePagesPerSec: swapRate,
                                 drivers: drivers)
    }

    public func activeAnomalies() -> [Anomaly] {
        let avail = Double((try? SystemStats.sample())?.availBytes ?? 0)
        return leaks.active().map { leak in
            var l = leak
            if leak.slopeMbPerHour > 1 {
                l.tteHours = avail / (leak.slopeMbPerHour * 1_048_576)
            }
            return l
        }
    }

    public func history(pid: Int32, minutes: Double) throws -> [ProcessSample] {
        try db.processHistory(pid: pid, since: Date().timeIntervalSince1970 - minutes * 60)
    }

    // MARK: - Chrome bridge (call on queue)

    public func chromeSync(tabs: [ChromeTab], focusedWindowId: Int?) -> [Int] {
        let wasConnected = chrome.connected()
        let result = chrome.sync(tabs: tabs, focusedWindowId: focusedWindowId)
        if !wasConnected {
            log("chrome extension connected (\(tabs.count) tabs)")
        }
        if result.refaults > 0 {
            try? db.markRefault(action: "chrome_discard_tabs", target: "Google Chrome",
                                since: Date().timeIntervalSince1970 - 600)
            log("chrome re-faults: \(result.refaults) discarded tab(s) reactivated")
        }
        if !result.discard.isEmpty {
            log("handing \(result.discard.count) tab discards to the chrome extension")
        }
        return result.discard
    }

    public func chromeStatus() -> ChromeStatus {
        chrome.status()
    }

    // MARK: - Action-type health (Acclaim re-fault loop)

    func refaultPrecision(action: String) -> Double {
        guard let stats = try? db.actionStats(action: action, sinceDays: 7),
              stats.total >= 4 else { return 1.0 }
        return 1.0 - Double(stats.refaults) / Double(stats.total)
    }

    func disabledActionTypes() -> Set<String> {
        var out = Set<String>()
        for action in ["sigstop_process", "chrome_discard_tabs", "docker_pause"] {
            if refaultPrecision(action: action) < 1.0 - Self.refaultDisableRate {
                out.insert(action)
            }
        }
        return out
    }

    // MARK: - Propose / execute / policy (callable from any thread)

    public func propose(useLLM: Bool, source: String) -> ProposalResult {
        let policy = (try? Policy.loadOrCreateDefault()) ?? .default
        let now = Date().timeIntervalSince1970

        var processes: [ProcessSample] = []
        var idle: [Int32: Double] = [:]
        var top: [ConsumerGroup] = []
        var leakList: [Anomaly] = []
        var suspended: Set<Int32> = []
        var chromeConnected = false
        var discardableTabs = 0
        var workedIn = Set<String>()
        var disabled = Set<String>()
        var budgetUsed = 0
        var lastByTarget: [String: Double] = [:]
        var pred = Prediction()
        queue.sync {
            processes = latestProcesses
            idle = idleTracker.idleSeconds()
            top = topConsumers(n: 10)
            leakList = activeAnomalies()
            suspended = Set(executor.suspensions.keys)
            chromeConnected = chrome.connected()
            discardableTabs = chrome.discardable().count
            workedIn = usage.appsRecentlyWorkedIn(now: now)
            disabled = disabledActionTypes()
            executedActionTimes.removeAll { now - $0 > 3600 }
            budgetUsed = executedActionTimes.count
            lastByTarget = lastActionByTarget
            pred = prediction()
        }
        let frontmost = Frontmost.appName()
        let system = (try? SystemStats.sample()) ?? SystemSnapshot(
            ts: now, totalBytes: 0, freeBytes: 0, activeBytes: 0,
            inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, purgeableBytes: 0,
            externalBytes: 0, internalBytes: 0, swapTotalBytes: 0, swapUsedBytes: 0,
            swapIns: 0, swapOuts: 0, pageIns: 0, pageOuts: 0, compressions: 0,
            pressureLevel: 1, availBytes: 0)

        var menu = PromptBuilder.legalMenu(processes: processes, idle: idle,
                                           frontmost: frontmost, policy: policy,
                                           suspendedPids: suspended)
        // Usage-model lookups and DB-backed precisions are queue-confined.
        var pReturns: [String: Double] = [:]
        var dwellMults: [String: Double] = [:]
        var precisions: [String: Double] = [:]
        queue.sync {
            for item in menu {
                pReturns[item.targetName] = usage.pReturn(app: item.targetName, now: now)
                dwellMults[item.targetName] = usage.dwellMultiplier(app: item.targetName, now: now)
            }
            for action in ["sigstop_process", "chrome_discard_tabs", "docker_pause"] {
                precisions[action] = refaultPrecision(action: action)
            }
        }
        // Rank by recovery-per-disruption (SmartLMK), best first.
        var scored: [(item: PromptBuilder.MenuItem, score: Double, pReturn: Double)] = menu.map { item in
            let pReturn = pReturns[item.targetName] ?? 0.2
            let score = ActionRanker.score(action: item.action, recoveryMb: item.footprintMb,
                                           pReturn: pReturn,
                                           dwellMult: dwellMults[item.targetName] ?? 1,
                                           refaultPrecision: precisions[item.action] ?? 1)
            return (item, score, pReturn)
        }
        if chromeConnected, discardableTabs > 0 {
            let recoveryMb = Double(discardableTabs) * ChromeBridge.estimatedMbPerTab
            let item = PromptBuilder.MenuItem(
                action: "chrome_discard_tabs", targetPid: 0, targetName: "Google Chrome",
                footprintMb: recoveryMb, idleSeconds: 0)
            let score = ActionRanker.score(action: item.action, recoveryMb: recoveryMb,
                                           pReturn: 0.3, dwellMult: 1,
                                           refaultPrecision: precisions[item.action] ?? 1)
            scored.append((item, score, 0.3))
        }
        scored.sort { $0.score > $1.score }
        menu = scored.map(\.item)

        var actions: [ProposedAction]
        var analysis: String?
        var confidence: String?
        var actualSource = "deterministic"
        let escalationHealth = claude.health(policy: policy).label

        if useLLM, case .available = claude.health(policy: policy) {
            let prompt = PromptBuilder.build(system: system, top: top, anomalies: leakList,
                                             prediction: pred, menu: menu, policy: policy)
            switch claude.propose(prompt: prompt, policy: policy) {
            case .success(let plan):
                actions = plan.plan
                analysis = plan.analysis
                confidence = plan.confidence
                actualSource = "llm"
                queue.sync { rateLimiter.recordSuccess() }
            case .failure(let err):
                log("escalation LLM failed (\(err)); using deterministic fallback")
                audit.append(kind: "escalation_llm_failure", data: ["error": "\(err)", "source": source])
                queue.sync { rateLimiter.recordFailure(now: now) }
                actions = deterministicPlan(scored: scored, top: top, leaks: leakList, policy: policy)
            }
        } else {
            actions = deterministicPlan(scored: scored, top: top, leaks: leakList, policy: policy)
        }

        let context = ValidationContext(
            frontmostAppName: frontmost,
            idleSeconds: idle,
            liveNames: Dictionary(processes.map { ($0.pid, $0.name) },
                                  uniquingKeysWith: { a, _ in a }),
            dockerAvailable: dockerAvailable,
            suspendedPids: suspended,
            chromeConnected: chromeConnected,
            chromeDiscardableTabs: discardableTabs,
            pressureLevel: system.pressureLevel,
            recentlyWorkedInApps: workedIn,
            disabledActionTypes: disabled,
            executedActionsLastHour: budgetUsed,
            lastActionTsByTarget: lastByTarget)
        let verdicts = Validator.validate(actions, policy: policy, context: context)

        queue.sync {
            pending = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.id, $0) })
        }

        let recovery = verdicts.filter(\.allowed)
            .compactMap(\.action.expectedMbFreed).reduce(0, +)
        let result = ProposalResult(source: actualSource, analysis: analysis,
                                    confidence: confidence, verdicts: verdicts,
                                    escalationHealth: escalationHealth,
                                    estimatedRecoveryMb: recovery)
        audit.append(kind: "proposal", data: [
            "source": actualSource, "trigger": source,
            "actions": verdicts.map { ["action": $0.action.action,
                                       "target": $0.action.targetName,
                                       "pid": Int($0.action.targetPid),
                                       "verdict": $0.verdict] },
        ])
        return result
    }

    /// Deterministic fallback: menu items already ranked by
    /// recovery-per-disruption, plus leak advisories and the biggest-consumer
    /// report.
    private func deterministicPlan(scored: [(item: PromptBuilder.MenuItem, score: Double, pReturn: Double)],
                                   top: [ConsumerGroup],
                                   leaks leakList: [Anomaly],
                                   policy: Policy) -> [ProposedAction] {
        var plan: [ProposedAction] = scored.prefix(policy.maxActionsPerEscalation).map { entry in
            let item = entry.item
            let reason: String
            if item.action == "chrome_discard_tabs" {
                reason = "suspend least-valuable inactive Chrome tabs (reload on click; active window untouched)"
            } else {
                reason = String(format: "idle manageable process, P(return soon)=%.2f, score %.0f",
                                entry.pReturn, entry.score)
            }
            return ProposedAction(action: item.action, targetPid: item.targetPid,
                                  targetName: item.targetName, reason: reason,
                                  expectedMbFreed: item.footprintMb)
        }
        // Rejuvenation advisory (Huang 1995): leaking + near exhaustion → recommend restart.
        for leak in leakList.prefix(2) where (leak.tteHours ?? .infinity) < 4 {
            plan.append(ProposedAction(
                action: "report", targetPid: leak.pid, targetName: leak.name,
                reason: String(format: "%@ is leaking %.0f MB/h (%.1fx its learned ceiling); at this rate memory exhausts in ~%.1f h — restarting it when convenient recovers %@",
                               leak.name, leak.slopeMbPerHour,
                               Double(leak.footprintBytes) / max(Double(leak.ceilingBytes), 1),
                               leak.tteHours ?? 0, formatBytes(leak.footprintBytes)),
                expectedMbFreed: nil))
        }
        if let biggest = top.first {
            plan.append(ProposedAction(
                action: "report", targetPid: 0, targetName: biggest.name,
                reason: "\(biggest.name) holds \(formatBytes(biggest.footprintBytes)) across \(biggest.processCount) processes — closing tabs/windows there recovers the most",
                expectedMbFreed: nil))
        }
        return plan
    }

    public func execute(actionID: String) -> ExecutionResult {
        let policy = (try? Policy.loadOrCreateDefault()) ?? .default
        let now = Date().timeIntervalSince1970
        guard let verdict = queue.sync(execute: { pending[actionID] }) else {
            return ExecutionResult(id: actionID, executed: false,
                                   detail: "unknown action id (propose first; ids expire on new proposals)",
                                   autoRevertAt: nil)
        }
        // Fresh context re-validation.
        var processes: [ProcessSample] = []
        var idle: [Int32: Double] = [:]
        var suspended: Set<Int32> = []
        var chromeConnected = false
        var discardableTabs = 0
        var workedIn = Set<String>()
        var disabled = Set<String>()
        var budgetUsed = 0
        var lastByTarget: [String: Double] = [:]
        var level = 1
        queue.sync {
            processes = latestProcesses
            idle = idleTracker.idleSeconds()
            suspended = Set(executor.suspensions.keys)
            chromeConnected = chrome.connected()
            discardableTabs = chrome.discardable().count
            workedIn = usage.appsRecentlyWorkedIn(now: now)
            disabled = disabledActionTypes()
            executedActionTimes.removeAll { now - $0 > 3600 }
            budgetUsed = executedActionTimes.count
            lastByTarget = lastActionByTarget
            level = SystemStats.pressureLevel()
        }
        let context = ValidationContext(
            frontmostAppName: Frontmost.appName(),
            idleSeconds: idle,
            liveNames: Dictionary(processes.map { ($0.pid, $0.name) },
                                  uniquingKeysWith: { a, _ in a }),
            dockerAvailable: dockerAvailable,
            suspendedPids: suspended,
            chromeConnected: chromeConnected,
            chromeDiscardableTabs: discardableTabs,
            pressureLevel: level,
            recentlyWorkedInApps: workedIn,
            disabledActionTypes: disabled,
            executedActionsLastHour: budgetUsed,
            lastActionTsByTarget: lastByTarget)
        guard let fresh = Validator.validate([verdict.action], policy: policy,
                                             context: context).first,
              fresh.allowed else {
            let why = Validator.validate([verdict.action], policy: policy,
                                         context: context).first?.verdict ?? "revalidation failed"
            audit.append(kind: "execute_refused", data: ["id": actionID, "verdict": why])
            return ExecutionResult(id: actionID, executed: false,
                                   detail: "refused on re-validation: \(why)", autoRevertAt: nil)
        }
        return queue.sync {
            pending.removeValue(forKey: actionID)
            let result: ExecutionResult
            if verdict.action.action == "chrome_discard_tabs" {
                // Size K to the recovery demand (bottom-K ranked tabs), min 3.
                let (thetaWarn, _) = predictor.thresholds(totalBytes: totalBytes)
                let avail = Double((try? SystemStats.sample())?.availBytes ?? 0)
                let demandMb = max(0, (thetaWarn - avail)) / 1_048_576
                let k = min(max(Int(ceil(demandMb / ChromeBridge.estimatedMbPerTab)), 3),
                            chrome.discardable().count)
                let count = chrome.enqueueDiscards(maxTabs: k)
                result = ExecutionResult(
                    id: actionID, executed: count > 0,
                    detail: "queued \(count) least-valuable tab discards (of \(chrome.discardable().count) eligible); extension applies within ~30s",
                    autoRevertAt: nil)
                audit.append(kind: "execute", data: [
                    "id": actionID, "action": "chrome_discard_tabs",
                    "tabs_queued": count, "executed": result.executed,
                ])
            } else {
                let kept = ActionVerdict(id: actionID, action: verdict.action,
                                         allowed: true, verdict: "allowed")
                result = executor.execute(kept, policy: policy, audit: audit)
            }
            if result.executed, verdict.action.action != "report" {
                executedActionTimes.append(now)
                lastActionByTarget[verdict.action.targetName] = now
                try? db.insertAction(ts: now, action: verdict.action.action,
                                     target: verdict.action.targetName,
                                     pid: verdict.action.targetPid)
            }
            return result
        }
    }

    public func setPolicy(autonomy: String?,
                          addManageable: [String], removeManageable: [String],
                          addProtected: [String], removeProtected: [String]) throws -> Policy {
        var policy = try Policy.loadOrCreateDefault()
        if let autonomy {
            guard Policy.autonomyLevels.contains(autonomy) else {
                throw NSError(domain: "memagent", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "autonomy must be one of \(Policy.autonomyLevels.sorted())"])
            }
            policy.autonomy = autonomy
        }
        policy.manageable = Array(Set(policy.manageable).union(addManageable)
            .subtracting(removeManageable)).sorted()
        policy.protected = Array(Set(policy.protected).union(addProtected)
            .subtracting(removeProtected)).sorted()
        try policy.save()
        claude.reset()
        audit.append(kind: "policy_set", data: [
            "autonomy": policy.autonomy,
            "manageable": policy.manageable,
            "protected_count": policy.protected.count,
        ])
        return policy
    }

    // MARK: - Autonomous escalation (on queue)

    private func maybeEscalate(trigger: String) {
        let policy = (try? Policy.loadOrCreateDefault()) ?? .default
        guard policy.autonomy != "off" else { return }
        let now = Date().timeIntervalSince1970
        guard !escalationInFlight,
              rateLimiter.allow(now: now,
                                minIntervalSeconds: policy.escalation.minIntervalSeconds,
                                maxPerHour: policy.escalation.maxPerHour) else { return }
        escalationInFlight = true
        rateLimiter.record(now: now)
        log("escalation triggered (\(trigger))")
        audit.append(kind: "escalation_trigger", data: ["trigger": trigger, "thrash": gauge.avg10])

        let thrashNow = gauge.avg10
        escalationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.propose(useLLM: true, source: trigger)
            // Auto-execution needs stronger corroboration than the trigger
            // (lmkd debounce: one action, then re-measure before the next).
            if policy.autonomy == "auto_reversible", thrashNow > 0.3 {
                for verdict in result.verdicts
                where verdict.allowed && verdict.action.action != "report" {
                    let exec = self.execute(actionID: verdict.id)
                    self.log("auto-executed \(verdict.action.action) on \(verdict.action.targetName): \(exec.detail)")
                    Thread.sleep(forTimeInterval: 20)
                    if SystemStats.pressureLevel() == 1 { break }
                }
            } else {
                let allowed = result.verdicts.filter(\.allowed).count
                self.log("escalation proposal ready (\(allowed) allowed actions; autonomy=\(policy.autonomy), thrash=\(String(format: "%.2f", thrashNow)) — nothing executed)")
            }
            self.queue.async { self.escalationInFlight = false }
        }
    }

    // MARK: - Logging

    public func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}

public struct DaemonInfo: Codable {
    public var version: String
    public var pid: Int32
    public var uptimeSeconds: Double
    public var rssBytes: UInt64
    public var suspensions: Int
    public var escalationHealth: String
    public var thrashIndex: Double
    public var thrashLabel: String
}
