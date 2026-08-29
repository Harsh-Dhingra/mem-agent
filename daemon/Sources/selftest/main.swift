import Foundation
import MemAgentCore

// Minimal assertion harness — the CLT toolchain has no XCTest/swift-testing.
var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String,
            file: String = #file, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL  \(label)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func approx(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

let total = 24.0 * 1_073_741_824  // 24 GB machine
let gb = 1_073_741_824.0
let mb = 1_048_576.0

// MARK: - Legacy predictor (kept for backtest comparison)

do {
    let samples: [(t: Double, avail: Double)] = (0..<60).map { i in
        let t = Double(i) * 10
        return (t, 20 * gb - (gb / 60.0) * t)
    }
    let p = LegacyPredictor.predict(samples: samples, totalBytes: total)
    expect(p.slopeBytesPerSec < 0 && p.confidence == "high" && p.etaMinutesToCritical != nil,
           "legacy: linear leak produces high-confidence ETA")

    let flat: [(t: Double, avail: Double)] = (0..<60).map { (Double($0) * 10, 15 * gb) }
    let pf = LegacyPredictor.predict(samples: flat, totalBytes: total)
    expect(pf.etaMinutesToCritical == nil, "legacy: flat series gives no ETA")
}

// MARK: - Damped Holt

do {
    var holt = HoltDamped(initialLevel: 20 * gb)
    for i in 1...120 {                       // steady -100 MB per step
        holt.update(20 * gb - Double(i) * 100 * mb)
    }
    expect(holt.trend < -60 * mb, "holt: trend learns the drain (got \(holt.trend / mb) MB/step)")
    let f90 = holt.forecast(steps: 90)
    let undamped = holt.level + 90 * holt.trend
    expect(f90 > undamped, "holt: damping tempers long-horizon extrapolation")
    expect(f90 < holt.level, "holt: forecast still heads downward")

    // Huberization: one absurd spike must not destroy the trend.
    let trendBefore = holt.trend
    holt.update(20 * gb)  // +8GB jump in one step
    expect(abs(holt.trend - trendBefore) < 0.5 * abs(trendBefore),
           "holt: single spike is clipped, trend survives")
}

// MARK: - Monte-Carlo first passage

do {
    var holt = HoltDamped(initialLevel: 10 * gb)
    for i in 1...90 { holt.update(10 * gb - Double(i) * 200 * mb) }  // fast drain
    let fp = holt.firstPassage(threshold: holt.level - 1 * gb, seed: 7)
    expect(fp.pWithin > 0.9, "mc: steep drain → crossing near-certain (got \(fp.pWithin))")
    if let p10 = fp.p10Steps, let med = fp.medianSteps {
        expect(p10 <= med, "mc: p10 arrives before the median")
    } else {
        expect(false, "mc: percentiles present on certain crossing")
    }

    var flat = HoltDamped(initialLevel: 10 * gb)
    var rng = SplitMix64(seed: 3)
    for _ in 1...90 { flat.update(10 * gb + rng.nextGaussian() * 50 * mb) }
    let fpFlat = flat.firstPassage(threshold: 2 * gb, seed: 7)
    expect(fpFlat.pWithin < 0.1, "mc: flat noise far from θ almost never crosses (got \(fpFlat.pWithin))")
}

// MARK: - Page-Hinkley regime detector

do {
    var ph = PageHinkley()
    var rng = SplitMix64(seed: 11)
    var falseAlarms = 0
    for _ in 0..<500 {
        if ph.observe(rng.nextGaussian() * 20 * mb) != .none { falseAlarms += 1 }
    }
    expect(falseAlarms <= 2, "ph: ≤2 false alarms on 500 flat noisy samples (got \(falseAlarms)) — a false reset only re-anchors the predictor")

    var detectDelay: Int? = nil
    for i in 1...40 {
        let dy = -150 * mb + rng.nextGaussian() * 20 * mb   // strong drain shift
        if ph.observe(dy) == .draining {
            detectDelay = i
            break
        }
    }
    expect(detectDelay != nil && detectDelay! <= 15,
           "ph: detects a strong drain shift within 15 samples (got \(String(describing: detectDelay)))")
}

// MARK: - Decayed histogram

do {
    var hist = DecayedHistogram(halfLife: 3600)
    let t0 = 1_000_000.0
    for i in 0..<100 { hist.add(2 * gb, at: t0 + Double(i)) }
    for i in 0..<100 { hist.add(8 * gb, at: t0 + 5 * 3600 + Double(i)) }  // 5 half-lives later
    let p50 = hist.percentile(0.5) ?? 0
    expect(approx(p50, 8 * gb, tolerance: gb), "histogram: decayed p50 tracks recent samples")
    let p1 = hist.percentile(0.01) ?? 0
    expect(p1 < 3 * gb, "histogram: deep percentile still remembers the old cluster")
    expect((hist.percentile(0.9) ?? 0) >= p50, "histogram: percentiles are monotone")
}

// MARK: - PredictionEngine end-to-end

do {
    let engine = PredictionEngine()
    var t = 0.0
    for _ in 0..<120 {  // 20 min flat at 20 GB
        engine.observe(t: t, avail: 20 * gb)
        t += 10
    }
    let calm = engine.predict(totalBytes: total, swapInRatePagesPerSec: 0, drivers: [], now: t)
    expect(calm.pPressure15min < 0.2, "engine: flat series → low P(pressure) (got \(calm.pPressure15min))")

    var avail = 20 * gb
    for _ in 0..<60 {   // 10 min of 250 MB/step drain
        avail -= 250 * mb
        engine.observe(t: t, avail: avail)
        t += 10
    }
    let alarmed = engine.predict(totalBytes: total, swapInRatePagesPerSec: 0, drivers: [], now: t)
    expect(alarmed.pPressure15min > 0.7,
           "engine: sustained drain → high P(pressure) (got \(alarmed.pPressure15min))")
    expect(engine.regimeShiftCount >= 1, "engine: drain onset triggered a regime reset")
    expect(alarmed.slopeBytesPerSec < 0, "engine: negative slope reported")
    let (warn, critical) = engine.thresholds(totalBytes: total)
    expect(critical >= 0.05 * total && warn > critical,
           "engine: learned thresholds sane (warn \(formatBytes(warn)) > critical \(formatBytes(critical)))")

    // θ cap: a machine that never felt pressure must not set θ at its own normal level.
    let cozy = PredictionEngine()
    var tc = 0.0
    for _ in 0..<600 { cozy.observe(t: tc, avail: 8 * gb); tc += 10 }
    let (_, thetaC) = cozy.thresholds(totalBytes: total)
    expect(thetaC <= 4 * gb + gb, "engine: θ capped at half the lived median (got \(formatBytes(thetaC)))")
    let cozyP = cozy.predict(totalBytes: total, swapInRatePagesPerSec: 0, drivers: [], now: tc)
    expect(cozyP.pPressure15min < 0.2, "engine: flat cozy machine never alarms (got \(cozyP.pPressure15min))")
}

// MARK: - Pressure gauge

func snap(ts: Double, swapIns: UInt64 = 0, swapOuts: UInt64 = 0,
          pageIns: UInt64 = 0, compressions: UInt64 = 0) -> SystemSnapshot {
    SystemSnapshot(ts: ts, totalBytes: UInt64(total), freeBytes: 0, activeBytes: 0,
                   inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, purgeableBytes: 0,
                   externalBytes: 0, internalBytes: 0, swapTotalBytes: 0, swapUsedBytes: 0,
                   swapIns: swapIns, swapOuts: swapOuts, pageIns: pageIns, pageOuts: 0,
                   compressions: compressions, pressureLevel: 1, availBytes: 0)
}

do {
    // Swap-outs alone = healthy offloading, never alarms.
    var gauge = PressureGauge()
    var outs: UInt64 = 0
    for i in 0..<20 {
        outs += 50_000
        gauge.observe(snap(ts: Double(i) * 10, swapOuts: outs), ncpu: 8)
    }
    expect(gauge.avg10 < 0.1, "gauge: swap-outs alone stay quiet (got \(gauge.avg10))")

    // Balanced swap in/out churn = real thrash.
    var thrash = PressureGauge()
    var ins: UInt64 = 0
    var comps: UInt64 = 0
    outs = 0
    for i in 0..<20 {
        ins += 200_000
        outs += 200_000
        comps += 200_000
        thrash.observe(snap(ts: Double(i) * 10, swapIns: ins, swapOuts: outs,
                            compressions: comps), ncpu: 8)
    }
    expect(thrash.avg10 > 0.3, "gauge: balanced swap churn alarms (got \(thrash.avg10))")
    expect(thrash.label == "thrashing" || thrash.label == "collapse",
           "gauge: severity label reflects churn (got \(thrash.label))")

    // Sleep gap backfills with zeros instead of reporting phantom pressure.
    var napped = thrash
    napped.observe(snap(ts: 20 * 10 + 3600, swapIns: ins, swapOuts: outs), ncpu: 8)
    expect(napped.avg10 < 0.05, "gauge: sleep gap decays the average (got \(napped.avg10))")
}

// MARK: - Leak statistics (pure functions)

do {
    let clean: [(t: Double, fp: Double)] = (0..<40).map { (Double($0) * 30, 400 * mb + Double($0) * 8 * mb) }
    let slope = LeakDetector.theilSen(clean)
    expect(approx(slope, 8 * mb / 30, tolerance: 0.1 * mb), "theil-sen: recovers the true slope")

    var dirty = clean
    for i in stride(from: 0, to: 40, by: 5) { dirty[i].fp += 3 * gb }
    let dirtySlope = LeakDetector.theilSen(dirty)
    expect(approx(dirtySlope, slope, tolerance: 0.5 * slope),
           "theil-sen: robust to 20% spike contamination")

    let zUp = LeakDetector.mannKendallZ(clean.map(\.fp))
    expect(zUp > 3, "mann-kendall: monotonic ramp is highly significant (z=\(zUp))")
    var rng = SplitMix64(seed: 5)
    let noise = (0..<40).map { _ in 400 * mb + rng.nextGaussian() * 50 * mb }
    let zNoise = abs(LeakDetector.mannKendallZ(noise))
    expect(zNoise < 2.5, "mann-kendall: noise is not significant (z=\(zNoise))")

    let survivors = LeakDetector.benjaminiHochberg([0.001, 0.5, 0.9, 0.002], q: 0.05)
    expect(survivors == [true, false, false, true], "benjamini-hochberg: small p-values survive")
    expect(LeakDetector.benjaminiHochberg([], q: 0.05).isEmpty, "benjamini-hochberg: empty input")
}

// MARK: - Leak detector behavior

func leakSample(pid: Int32, name: String, mbFp: Double, at t: Double) -> ProcessSample {
    ProcessSample(ts: t, pid: pid, name: name, footprintBytes: UInt64(mbFp * mb),
                  residentBytes: 0, cpuTime: 0, source: "rusage")
}

do {
    // A process leaking hard inside its first 15 min: warmup gate holds fire.
    let det = LeakDetector()
    var t = 0.0
    for i in 0..<28 {  // 14 min of aggressive ramp
        det.ingest([leakSample(pid: 1, name: "fresh", mbFp: 200 + Double(i) * 50, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "leak: warmup gate suppresses first-15-min growth")
}

do {
    // Established baseline then a genuine linear leak → flags.
    let det = LeakDetector()
    var t = 0.0
    for _ in 0..<360 {  // 3 h at 400 MB
        det.ingest([leakSample(pid: 2, name: "leaky", mbFp: 400, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "leak: stable baseline stays quiet")
    var fp = 400.0
    var flagged = false
    for _ in 0..<80 {   // 40 min at ~16 MB per 30s ≈ 1.9 GB/h
        fp += 16
        det.ingest([leakSample(pid: 2, name: "leaky", mbFp: fp, at: t)])
        t += 30
        if !det.active().isEmpty { flagged = true; break }
    }
    expect(flagged, "leak: sustained linear leak past ceiling flags")
    if let leak = det.active().first {
        expect(leak.slopeMbPerHour > 1000, "leak: slope estimate near 1.9 GB/h (got \(leak.slopeMbPerHour))")
        expect(leak.ceilingBytes > UInt64(400 * mb), "leak: ceiling learned from own history")
    }
}

do {
    // Saturating (cache-warming) growth after a baseline → never flags.
    let det = LeakDetector()
    var t = 0.0
    for _ in 0..<360 {
        det.ingest([leakSample(pid: 3, name: "warming", mbFp: 400, at: t)])
        t += 30
    }
    let rampStart = t
    for _ in 0..<80 {
        let elapsed = t - rampStart
        let fp = 400 + 1200 * (1 - exp(-elapsed / 180))  // saturates fast
        det.ingest([leakSample(pid: 3, name: "warming", mbFp: fp, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "leak: asymptotic cache warm-up is not a leak")
}

do {
    // Large but stable process never flags.
    let det = LeakDetector()
    var t = 0.0
    for _ in 0..<400 {
        det.ingest([leakSample(pid: 4, name: "Chrome", mbFp: 12_000, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "leak: stable 12 GB process never flags")
}

// MARK: - Usage model

do {
    let usage = UsageModel()
    var t = 0.0
    for _ in 0..<30 {   // strong sequential habit A → B → C
        for app in ["A", "B", "C"] {
            usage.observeFrontmost(app, at: t)
            t += 120
        }
    }
    usage.observeFrontmost("A", at: t); t += 120
    usage.observeFrontmost("B", at: t); t += 120
    let pC = usage.pReturn(app: "C", now: t)
    let pA = usage.pReturn(app: "A", now: t)
    expect(pC > pA, "usage: PPM predicts the sequential next app (C \(pC) vs A \(pA))")
    expect(usage.pReturn(app: "never-seen", now: t) < 0.2, "usage: unknown app gets a weak prior")

    let dwell = UsageModel()
    dwell.observeFrontmost("Editor", at: 0)
    dwell.observeFrontmost("Slack", at: 600)      // Editor dwelled 10 min
    expect(dwell.recentlyWorkedIn(app: "Editor", now: 900),
           "usage: 10-min dwell protects for 20 min after")
    expect(!dwell.recentlyWorkedIn(app: "Editor", now: 600 + 1300),
           "usage: dwell protection expires")
    dwell.observeFrontmost("Deep Work", at: 2000)
    expect(dwell.recentlyWorkedIn(app: "Deep Work", now: 2000 + 400),
           "usage: current long dwell protects mid-session")
    expect(dwell.dwellMultiplier(app: "Deep Work", now: 2000 + 900) >= 1.5,
           "usage: dwell multiplier grows with session length")
}

// MARK: - Action ranker

do {
    let base = ActionRanker.score(action: "sigstop_process", recoveryMb: 800,
                                  pReturn: 0.2, dwellMult: 1, refaultPrecision: 1)
    let bigger = ActionRanker.score(action: "sigstop_process", recoveryMb: 1600,
                                    pReturn: 0.2, dwellMult: 1, refaultPrecision: 1)
    let comeback = ActionRanker.score(action: "sigstop_process", recoveryMb: 800,
                                      pReturn: 0.9, dwellMult: 2, refaultPrecision: 1)
    let mistrusted = ActionRanker.score(action: "sigstop_process", recoveryMb: 800,
                                        pReturn: 0.2, dwellMult: 1, refaultPrecision: 0.5)
    expect(bigger > base, "ranker: more recovery scores higher")
    expect(comeback < base, "ranker: likely-to-return target scores lower")
    expect(mistrusted < base, "ranker: measured re-faults discount the action type")
}

// MARK: - Validator decision table (incl. v0.3 rules)

do {
    var policy = Policy.default
    policy.manageable = ["ollama", "idle-helper"]
    policy.autonomy = "suggest"

    func ctx(_ mutate: (inout ValidationContext) -> Void = { _ in }) -> ValidationContext {
        var c = ValidationContext(
            frontmostAppName: "Cursor",
            idleSeconds: [100: 3000, 200: 3000, 300: 600, 400: 3000, 500: 3000,
                          600: 3000, 800: 3000, 900: 3000],
            liveNames: [100: "ollama", 200: "Terminal", 300: "idle-helper",
                        400: "Cursor", 500: "random-app", 600: "idle-helper",
                        800: "ollama", 900: "ollama"],
            dockerAvailable: false,
            suspendedPids: [800],
            pressureLevel: 2,
            now: 100_000)
        mutate(&c)
        return c
    }

    func act(_ action: String = "sigstop_process", pid: Int32, name: String) -> ProposedAction {
        ProposedAction(action: action, targetPid: pid, targetName: name, reason: "test")
    }

    func verdict(_ a: ProposedAction, _ p: Policy = policy,
                 _ c: ValidationContext) -> ActionVerdict {
        Validator.validate([a], policy: p, context: c)[0]
    }

    expect(verdict(act(pid: 100, name: "ollama"), policy, ctx()).allowed,
           "validator: idle manageable process allowed")
    expect(!verdict(act(pid: 200, name: "Terminal"), policy, ctx()).allowed,
           "validator: protected app denied")
    expect(!verdict(act(pid: 300, name: "idle-helper"), policy, ctx()).allowed,
           "validator: WARN band requires 30-min idle (600s denied)")
    expect(verdict(act(pid: 300, name: "idle-helper"), policy,
                   ctx { $0.pressureLevel = 4 }).allowed,
           "validator: CRITICAL band accepts 5-min idle")
    expect(!verdict(act(pid: 400, name: "Cursor"), policy, ctx()).allowed,
           "validator: frontmost app denied")
    expect(!verdict(act(pid: 500, name: "random-app"), policy, ctx()).allowed,
           "validator: not-in-allowlist denied")
    expect(!verdict(act(pid: 999, name: "ollama"), policy, ctx()).allowed,
           "validator: dead pid denied")
    expect(!verdict(act(pid: 100, name: "not-ollama"), policy, ctx()).allowed,
           "validator: pid/name mismatch denied")
    expect(!verdict(act("docker_pause", pid: 100, name: "ollama"), policy, ctx()).allowed,
           "validator: docker denied when CLI absent")
    expect(!verdict(act("rm_rf", pid: 100, name: "ollama"), policy, ctx()).allowed,
           "validator: unknown action denied")
    expect(!verdict(act(pid: 800, name: "ollama"), policy, ctx()).allowed,
           "validator: already-suspended pid denied")
    expect(verdict(ProposedAction(action: "report", targetPid: 0, targetName: "x",
                                  reason: "info"), policy, ctx()).allowed,
           "validator: report always allowed")

    var offPolicy = policy
    offPolicy.autonomy = "off"
    expect(!verdict(act(pid: 100, name: "ollama"), offPolicy, ctx()).allowed,
           "validator: autonomy off denies")

    expect(!verdict(act(pid: 100, name: "ollama"), policy,
                    ctx { $0.recentlyWorkedInApps = ["ollama"] }).allowed,
           "validator: Iqbal-Horvitz dwell rule denies recently-worked-in app")
    expect(!verdict(act(pid: 100, name: "ollama"), policy,
                    ctx { $0.executedActionsLastHour = 4 }).allowed,
           "validator: hourly disruption budget enforced")
    expect(!verdict(act(pid: 100, name: "ollama"), policy,
                    ctx { $0.lastActionTsByTarget = ["ollama": 100_000 - 900] }).allowed,
           "validator: 30-min per-target cooldown enforced")
    expect(verdict(act(pid: 100, name: "ollama"), policy,
                   ctx { $0.lastActionTsByTarget = ["ollama": 100_000 - 2000] }).allowed,
           "validator: cooldown expires")
    expect(!verdict(act(pid: 100, name: "ollama"), policy,
                    ctx { $0.disabledActionTypes = ["sigstop_process"] }).allowed,
           "validator: re-fault auto-disabled type denied")

    let chromeAction = ProposedAction(action: "chrome_discard_tabs", targetPid: 0,
                                      targetName: "Google Chrome", reason: "t")
    expect(verdict(chromeAction, policy,
                   ctx { $0.chromeConnected = true; $0.chromeDiscardableTabs = 9 }).allowed,
           "validator: chrome discard allowed when connected")
    expect(!verdict(chromeAction, policy, ctx()).allowed,
           "validator: chrome discard denied when not connected")

    var capPolicy = policy
    capPolicy.maxActionsPerEscalation = 1
    let many = [act(pid: 100, name: "ollama"), act(pid: 600, name: "idle-helper")]
    expect(Validator.validate(many, policy: capPolicy, context: ctx()).filter(\.allowed).count == 1,
           "validator: per-escalation cap enforced")

    var patternPolicy = policy
    patternPolicy.manageable = ["Chrome Helper (GPU) thing"]
    expect(!verdict(act(pid: 900, name: "Chrome Helper (GPU) thing"), patternPolicy,
                    ctx { $0.liveNames[900] = "Chrome Helper (GPU) thing" }).allowed,
           "validator: glob pattern protection wins")
}

// MARK: - Chrome bridge

do {
    let now = 1_000_000.0
    func tab(_ id: Int, window: Int = 1, active: Bool = false, audible: Bool = false,
             pinned: Bool = false, discarded: Bool = false, idleMinutes: Double = 30,
             host: String = "example.com") -> ChromeTab {
        ChromeTab(id: id, windowId: window, active: active, audible: audible, pinned: pinned,
                  discarded: discarded, lastAccessed: (now - idleMinutes * 60) * 1000,
                  urlHost: host, title: "t\(id)")
    }

    let bridge = ChromeBridge()
    _ = bridge.sync(tabs: [
        tab(1), tab(2, active: true), tab(3, audible: true), tab(4, pinned: true),
        tab(5, discarded: true), tab(6, idleMinutes: 2),
        tab(7, window: 9), tab(8, idleMinutes: 300),
    ], focusedWindowId: 9, at: now)
    let discardable = bridge.discardable(at: now).map(\.id).sorted()
    expect(discardable == [1, 8],
           "chrome: vetoes cover active/audible/pinned/discarded/recent/focused-window (got \(discardable))")

    expect(bridge.enqueueDiscards(maxTabs: 1, at: now) == 1, "chrome: bottom-K queues one")
    let handed = bridge.sync(tabs: [tab(1), tab(8, idleMinutes: 300)],
                             focusedWindowId: nil, at: now + 10)
    expect(handed.discard == [8], "chrome: stalest tab discarded first (got \(handed.discard))")

    let refaultSync = bridge.sync(tabs: [tab(1), tab(8, idleMinutes: 300)],
                                  focusedWindowId: nil, at: now + 120)
    expect(refaultSync.refaults == 1, "chrome: reactivated discard counted as re-fault")
    expect(bridge.status(at: now + 130).reactivations == 1, "chrome: reactivation total tracked")
    let protectedPriority = bridge.discardPriority(tab(8, idleMinutes: 300), now: now + 130)
    let freshPriority = bridge.discardPriority(tab(1, idleMinutes: 300, host: "other.com"), now: now + 130)
    expect(protectedPriority < freshPriority, "chrome: re-faulted host earns ranking protection")
}

// MARK: - Escalation plan parsing + rate limiter

do {
    let clean = """
    {"analysis": "x", "confidence": "high", "plan": [{"action": "chrome_discard_tabs", "target_pid": 0, "target_name": "Google Chrome", "reason": "tabs", "expected_mb_freed": 900}]}
    """
    expect(EscalationPlan.parse(fromModelOutput: "text\n```json\n\(clean)\n```")?.plan.count == 1,
           "escalation parse: fenced JSON with new action type")
    expect(EscalationPlan.parse(fromModelOutput: "no json here") == nil,
           "escalation parse: garbage → nil")

    var rl = RateLimiter()
    let t0 = 1000.0
    expect(rl.allow(now: t0, minIntervalSeconds: 900, maxPerHour: 3), "ratelimit: first allowed")
    rl.record(now: t0)
    expect(!rl.allow(now: t0 + 600, minIntervalSeconds: 900, maxPerHour: 3),
           "ratelimit: min interval enforced")
    var breaker = RateLimiter()
    breaker.recordFailure(now: t0)
    breaker.recordFailure(now: t0 + 1)
    breaker.recordFailure(now: t0 + 2)
    expect(!breaker.allow(now: t0 + 3, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: opens after 3 failures")
    expect(breaker.allow(now: t0 + 2 + 3601, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: cooldown closes it")
}

// MARK: - Policy tolerant decoding

do {
    let p = try JSON.decoder.decode(Policy.self, from: Data("{\"autonomy\": \"auto_reversible\"}".utf8))
    expect(p.autonomy == "auto_reversible" && p.minIdleSeconds == 60 && !p.protected.isEmpty,
           "policy: partial file decodes with defaults")
} catch {
    expect(false, "policy: tolerant decode threw \(error)")
}

// MARK: - Database round-trip (temp file)

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("memagent-selftest-\(getpid()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let db = try Database(path: tmp.path)
    var s = try SystemStats.sample()
    s.availBytes = 12_345_678
    try db.insert(system: s)
    let series = try db.systemSeries(since: s.ts - 1)
    expect(series.count == 1 && series[0].avail == 12_345_678, "db: system series round-trips")

    try db.saveBlob(key: "k", json: "{\"a\":1}")
    try db.saveBlob(key: "k", json: "{\"a\":2}")
    expect(try db.loadBlob(key: "k") == "{\"a\":2}", "db: blob upsert round-trips")
    expect(try db.loadBlob(key: "missing") == nil, "db: missing blob is nil")

    let now = Date().timeIntervalSince1970
    try db.insertAction(ts: now - 100, action: "sigstop_process", target: "ollama", pid: 42)
    try db.insertAction(ts: now - 50, action: "sigstop_process", target: "ollama", pid: 42)
    try db.markRefault(action: "sigstop_process", target: "ollama", since: now - 60)
    let stats = try db.actionStats(action: "sigstop_process", sinceDays: 1)
    expect(stats.total == 2 && stats.refaults == 1, "db: action stats count re-faults (got \(stats))")
} catch {
    expect(false, "db: unexpected error \(error)")
}

// MARK: - Backtest on a synthetic trace

do {
    var series: [(t: Double, avail: Double, level: Int)] = []
    var t = 0.0
    for _ in 0..<360 { series.append((t, 8 * gb, 1)); t += 10 }        // 1 h calm
    var avail = 8 * gb
    for _ in 0..<180 {                                                  // 30-min drain
        avail -= 43 * mb
        series.append((t, max(avail, 0.3 * gb), avail < 2.4 * gb ? 2 : 1))
        t += 10
    }
    for _ in 0..<60 { series.append((t, 0.3 * gb, 2)); t += 10 }        // held low
    let report = Backtest.run(series: series, totalBytes: total)
    expect(report.warnEpisodes == 1, "backtest: one ground-truth episode (got \(report.warnEpisodes))")
    expect(report.episodesCaughtNew == 1, "backtest: v0.3 engine anticipates the episode")
    // The earliest alert can precede the kernel's warn flip by more than the
    // 15-min truth window while still being a correct θ-crossing forecast —
    // allow one such "too early" alert.
    expect(report.alertsNew > 0 && report.truePositivesNew >= report.alertsNew - 1,
           "backtest: v0.3 alerts near-all true positives (\(report.truePositivesNew)/\(report.alertsNew))")
}

// MARK: - Live sensor sanity (this machine)

do {
    let s = try SystemStats.sample()
    expect(s.totalBytes > 4 * UInt64(gb), "sensors: total memory > 4 GB")
    expect([1, 2, 4].contains(s.pressureLevel), "sensors: pressure level is 1/2/4")
    let sweep = ProcessStats.sweep()
    expect(sweep.samples.count > 50, "sensors: sees >50 processes")
    expect(sweep.rusageCount > 10, "sensors: rusage works unprivileged")
} catch {
    expect(false, "sensors: unexpected error \(error)")
}

print(failures == 0
      ? "OK — \(checks) checks passed"
      : "FAILED — \(failures)/\(checks) checks failed")
exit(failures == 0 ? 0 : 1)
