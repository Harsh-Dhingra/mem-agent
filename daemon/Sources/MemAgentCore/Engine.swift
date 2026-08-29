import Dispatch
import Foundation
import CLibProc

/// The daemon's authoritative state: sampling loops, history, prediction,
/// anomaly detection, and (Phase D) the propose/execute pipeline. Mutable
/// state is serialized on `queue`; the LLM call runs on `escalationQueue` so
/// it can never stall sampling or the socket.
public final class Engine {
    public let queue = DispatchQueue(label: "memagent.engine")
    private let escalationQueue = DispatchQueue(label: "memagent.escalation")
    let db: Database
    let anomalies = AnomalyDetector()
    let idleTracker = IdleTracker()
    let executor = Executor()
    let chrome = ChromeBridge()
    let claude = ClaudeCLI()
    let audit = Audit(url: Paths.auditLog)
    let startedAt = Date()

    // In-memory ring of recent (t, avail) for the predictor (~45 min).
    private var availRing: [(t: Double, avail: Double)] = []
    private var latestProcesses: [ProcessSample] = []
    private var swapInEwma = EWMA(halfLife: 120)
    private var lastSwapIns: (t: Double, pages: UInt64)?
    private var totalBytes: Double = 0

    // Phase D state (on queue).
    private var pending: [String: ActionVerdict] = [:]
    private var rateLimiter = RateLimiter()
    private var escalationInFlight = false
    private let dockerAvailable = Executor.dockerAvailable()

    private var timers: [DispatchSourceTimer] = []
    private var pressureSource: PressureSource?

    public static let systemInterval = 10.0
    public static let processInterval = 30.0
    public static let processTopN = 40
    // The anomaly detector watches a wider set than the DB stores: on a loaded
    // machine the top-40 cutoff can exceed 300 MB, which would seed a growing
    // process's baseline too late (cold-start blindness).
    public static let detectorFloorBytes: UInt64 = 100 * 1_048_576
    public static let detectorMaxProcesses = 150
    /// Autonomous escalation fires when ETA-to-critical drops below this.
    public static let escalationEtaMinutes = 10.0

    public init(db: Database) {
        self.db = db
        self.totalBytes = Double((try? SystemStats.totalMemory()) ?? 0)
    }

    // MARK: - Lifecycle

    public func start() {
        schedule(interval: Self.systemInterval) { [weak self] in self?.sampleSystem() }
        schedule(interval: Self.processInterval) { [weak self] in self?.sampleProcesses() }
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
        // Prime immediately so the socket has data from second zero.
        queue.async {
            self.sampleSystem()
            self.sampleProcesses()
        }
    }

    /// Called on SIGINT/SIGTERM: never leave anything suspended behind us.
    public func shutdown() {
        queue.sync {
            executor.revertAll(audit: audit)
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
            availRing.append((snap.ts, Double(snap.availBytes)))
            let cutoff = snap.ts - 45 * 60
            availRing.removeAll { $0.t < cutoff }

            if let last = lastSwapIns, snap.ts > last.t {
                let rate = Double(snap.swapIns &- min(snap.swapIns, last.pages)) / (snap.ts - last.t)
                swapInEwma.add(rate, at: snap.ts)
            }
            lastSwapIns = (snap.ts, snap.swapIns)

            // Predictive trigger: a stable trend says critical is close.
            let p = prediction()
            if let eta = p.etaMinutesToCritical, eta < Self.escalationEtaMinutes,
               p.confidence != "low" {
                maybeEscalate(trigger: "eta_\(Int(eta))min")
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
        let active = anomalies.ingest(Array(watched))
        for a in active {
            log("anomaly: \(a.name) (pid \(a.pid)) grew \(formatBytes(a.growthBytes)) above baseline")
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
            escalationHealth: rateLimiter.health(now: Date().timeIntervalSince1970))
        return (snap, info)
    }

    public func topConsumers(n: Int) -> [ConsumerGroup] {
        Array(ProcessStats.group(latestProcesses).prefix(n))
    }

    public func prediction() -> Prediction {
        let swapRate = swapInEwma.value ?? 0
        var drivers: [String] = []
        for a in anomalies.active().prefix(3) {
            drivers.append("\(a.name) (pid \(a.pid)) grew \(formatBytes(a.growthBytes)) above its 30-min baseline")
        }
        if swapRate > 100 {
            drivers.append(String(format: "swap-in rate %.0f pages/s", swapRate))
        }
        if drivers.isEmpty, let top = topConsumers(n: 1).first {
            drivers.append("largest consumer: \(top.name) at \(formatBytes(top.footprintBytes))")
        }
        return Predictor.predict(
            samples: availRing,
            totalBytes: totalBytes,
            swapInRatePagesPerSec: swapRate,
            drivers: drivers)
    }

    public func activeAnomalies() -> [Anomaly] {
        anomalies.active()
    }

    public func history(pid: Int32, minutes: Double) throws -> [ProcessSample] {
        try db.processHistory(pid: pid, since: Date().timeIntervalSince1970 - minutes * 60)
    }

    // MARK: - Chrome bridge (call on queue)

    public func chromeSync(tabs: [ChromeTab]) -> [Int] {
        let wasConnected = chrome.connected()
        let discards = chrome.sync(tabs: tabs)
        if !wasConnected {
            log("chrome extension connected (\(tabs.count) tabs)")
        }
        if !discards.isEmpty {
            log("handing \(discards.count) tab discards to the chrome extension")
        }
        return discards
    }

    public func chromeStatus() -> ChromeStatus {
        chrome.status()
    }

    // MARK: - Phase D: propose / execute / policy (callable from any thread)

    /// Build a proposal: LLM if requested and available, deterministic
    /// otherwise. Blocks the calling thread (up to the escalation timeout)
    /// when useLLM is true — never call it on `queue`.
    public func propose(useLLM: Bool, source: String) -> ProposalResult {
        let policy = (try? Policy.loadOrCreateDefault()) ?? .default

        // Snapshot state on the engine queue.
        var processes: [ProcessSample] = []
        var idle: [Int32: Double] = [:]
        var top: [ConsumerGroup] = []
        var anomalyList: [Anomaly] = []
        var suspended: Set<Int32> = []
        var chromeConnected = false
        var discardableTabs = 0
        var pred = Prediction(etaMinutesToWarn: nil, etaMinutesToCritical: nil,
                              confidence: "low", slopeBytesPerSec: 0, availBytes: 0,
                              swapInRatePagesPerSec: 0, drivers: [])
        queue.sync {
            processes = latestProcesses
            idle = idleTracker.idleSeconds()
            top = topConsumers(n: 10)
            anomalyList = anomalies.active()
            suspended = Set(executor.suspensions.keys)
            chromeConnected = chrome.connected()
            discardableTabs = chrome.discardable().count
            pred = prediction()
        }
        let frontmost = Frontmost.appName()
        let system = (try? SystemStats.sample()) ?? SystemSnapshot(
            ts: Date().timeIntervalSince1970, totalBytes: 0, freeBytes: 0, activeBytes: 0,
            inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, purgeableBytes: 0,
            externalBytes: 0, internalBytes: 0, swapTotalBytes: 0, swapUsedBytes: 0,
            swapIns: 0, swapOuts: 0, pageIns: 0, pageOuts: 0, compressions: 0,
            pressureLevel: 1, availBytes: 0)

        var menu = PromptBuilder.legalMenu(processes: processes, idle: idle,
                                           frontmost: frontmost, policy: policy,
                                           suspendedPids: suspended)
        if chromeConnected, discardableTabs > 0 {
            // The single biggest lever on most machines goes first in the menu.
            menu.insert(PromptBuilder.MenuItem(
                action: "chrome_discard_tabs", targetPid: 0, targetName: "Google Chrome",
                footprintMb: Double(discardableTabs) * ChromeBridge.estimatedMbPerTab,
                idleSeconds: 0), at: 0)
        }

        var actions: [ProposedAction]
        var analysis: String?
        var confidence: String?
        var actualSource = "deterministic"
        let escalationHealth = claude.health(policy: policy).label

        if useLLM, case .available = claude.health(policy: policy) {
            let prompt = PromptBuilder.build(system: system, top: top, anomalies: anomalyList,
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
                queue.sync { rateLimiter.recordFailure(now: Date().timeIntervalSince1970) }
                actions = deterministicPlan(menu: menu, top: top, policy: policy)
            }
        } else {
            actions = deterministicPlan(menu: menu, top: top, policy: policy)
        }

        // The safety core: whatever the source, everything is re-validated.
        let context = ValidationContext(
            frontmostAppName: frontmost,
            idleSeconds: idle,
            liveNames: Dictionary(processes.map { ($0.pid, $0.name) },
                                  uniquingKeysWith: { a, _ in a }),
            dockerAvailable: dockerAvailable,
            suspendedPids: suspended,
            chromeConnected: chromeConnected,
            chromeDiscardableTabs: discardableTabs)
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

    /// Fallback when no LLM is reachable: largest idle manageable processes,
    /// plus a report naming the biggest consumer overall.
    private func deterministicPlan(menu: [PromptBuilder.MenuItem],
                                   top: [ConsumerGroup],
                                   policy: Policy) -> [ProposedAction] {
        var plan: [ProposedAction] = menu.prefix(policy.maxActionsPerEscalation).map { item in
            let reason = item.action == "chrome_discard_tabs"
                ? "suspend inactive Chrome tabs (reload on click; skips active/pinned/audible)"
                : "largest idle manageable process (idle \(Int(item.idleSeconds))s)"
            return ProposedAction(action: item.action, targetPid: item.targetPid,
                                  targetName: item.targetName,
                                  reason: reason,
                                  expectedMbFreed: item.footprintMb)
        }
        if let biggest = top.first {
            plan.append(ProposedAction(
                action: "report", targetPid: 0, targetName: biggest.name,
                reason: "\(biggest.name) holds \(formatBytes(biggest.footprintBytes)) across \(biggest.processCount) processes — closing tabs/windows there recovers the most",
                expectedMbFreed: nil))
        }
        return plan
    }

    /// Execute one previously proposed action by id, re-validating first —
    /// the world may have changed since the proposal.
    public func execute(actionID: String) -> ExecutionResult {
        let policy = (try? Policy.loadOrCreateDefault()) ?? .default
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
        queue.sync {
            processes = latestProcesses
            idle = idleTracker.idleSeconds()
            suspended = Set(executor.suspensions.keys)
            chromeConnected = chrome.connected()
            discardableTabs = chrome.discardable().count
        }
        let context = ValidationContext(
            frontmostAppName: Frontmost.appName(),
            idleSeconds: idle,
            liveNames: Dictionary(processes.map { ($0.pid, $0.name) },
                                  uniquingKeysWith: { a, _ in a }),
            dockerAvailable: dockerAvailable,
            suspendedPids: suspended,
            chromeConnected: chromeConnected,
            chromeDiscardableTabs: discardableTabs)
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
            if verdict.action.action == "chrome_discard_tabs" {
                // Tab-level action: queued here, applied by the extension on
                // its next sync (≤30s). Non-destructive, so no revert tracking.
                let count = chrome.enqueueDiscardAll()
                let result = ExecutionResult(
                    id: actionID, executed: count > 0,
                    detail: "queued \(count) inactive tab discards; the Chrome extension applies them within ~30s",
                    autoRevertAt: nil)
                audit.append(kind: "execute", data: [
                    "id": actionID, "action": "chrome_discard_tabs",
                    "tabs_queued": count, "executed": result.executed,
                ])
                return result
            }
            let kept = ActionVerdict(id: actionID, action: verdict.action,
                                     allowed: true, verdict: "allowed")
            let result = executor.execute(kept, policy: policy, audit: audit)
            return result
        }
    }

    /// Autonomy + allowlist edits only — the rest of the policy is edited in
    /// the file directly.
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
        audit.append(kind: "escalation_trigger", data: ["trigger": trigger])

        escalationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.propose(useLLM: true, source: trigger)
            if policy.autonomy == "auto_reversible" {
                for verdict in result.verdicts
                where verdict.allowed && verdict.action.action != "report" {
                    let exec = self.execute(actionID: verdict.id)
                    self.log("auto-executed \(verdict.action.action) on \(verdict.action.targetName): \(exec.detail)")
                }
            } else {
                let allowed = result.verdicts.filter(\.allowed).count
                self.log("escalation proposal ready (\(allowed) allowed actions, autonomy=suggest — nothing executed)")
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
}
