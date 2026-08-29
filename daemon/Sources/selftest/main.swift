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

let total = 36.0 * 1_073_741_824  // 36 GB machine
let gb = 1_073_741_824.0

// MARK: - Predictor

do {
    // Steady leak of 1 GB/min from 20 GB avail → ETA to critical (5% = 1.8 GB)
    // avail(t) = 20 GB - (1 GB per minute) * t, sampled every 10s for 10 min.
    let samples: [(t: Double, avail: Double)] = (0..<60).map { i in
        let t = Double(i) * 10
        return (t, 20 * gb - (gb / 60.0) * t)
    }
    let p = Predictor.predict(samples: samples, totalBytes: total)
    expect(p.slopeBytesPerSec < 0, "linear leak: slope negative")
    expect(p.confidence == "high", "linear leak: high confidence, got \(p.confidence)")
    let availNow = samples.last!.avail
    let expected = (availNow - total * 0.05) / (gb / 60.0) / 60.0
    expect(p.etaMinutesToCritical != nil, "linear leak: critical ETA present")
    if let eta = p.etaMinutesToCritical {
        expect(approx(eta, expected, tolerance: expected * 0.15),
               "linear leak: ETA ≈ \(expected) min, got \(eta)")
    }
    if let warn = p.etaMinutesToWarn, let crit = p.etaMinutesToCritical {
        expect(warn < crit, "linear leak: warn ETA before critical ETA")
    } else {
        expect(false, "linear leak: warn ETA present")
    }
}

do {
    // Noisy but flat series → no ETA.
    var rng = SystemRandomNumberGenerator()
    let samples: [(t: Double, avail: Double)] = (0..<120).map { i in
        let noise = Double(Int.random(in: -500...500, using: &rng)) * 1_048_576
        return (Double(i) * 10, 15 * gb + noise)
    }
    let p = Predictor.predict(samples: samples, totalBytes: total)
    expect(p.etaMinutesToCritical == nil, "noisy flat: no critical ETA")
    expect(p.etaMinutesToWarn == nil, "noisy flat: no warn ETA")
}

do {
    // Too few samples → graceful low-confidence output.
    let p = Predictor.predict(samples: [(0, 1e9), (10, 9e8)], totalBytes: total)
    expect(p.etaMinutesToCritical == nil, "few samples: no ETA")
    expect(p.confidence == "low", "few samples: low confidence")
}

do {
    // Already below the critical threshold → ETA clamps to 0, never negative.
    let samples: [(t: Double, avail: Double)] = (0..<60).map { i in
        (Double(i) * 10, 1.5 * gb - Double(i) * 1_048_576)
    }
    let p = Predictor.predict(samples: samples, totalBytes: total)
    if let eta = p.etaMinutesToCritical {
        expect(eta == 0, "below threshold: ETA clamps to 0, got \(eta)")
    }
}

// MARK: - AnomalyDetector

func procSample(pid: Int32, name: String, mb: Double, at t: Double) -> ProcessSample {
    ProcessSample(ts: t, pid: pid, name: name,
                  footprintBytes: UInt64(mb * 1_048_576),
                  residentBytes: 0, cpuTime: 0, source: "rusage")
}

do {
    // 400 MB baseline then a fast ramp → fires after the sustained window.
    let det = AnomalyDetector()
    var t = 0.0
    for _ in 0..<30 {
        det.ingest([procSample(pid: 100, name: "tsserver", mb: 400, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "anomaly: quiet during stable baseline")
    var fired = false
    for step in 0..<20 {
        let mb = 400 + Double(step) * 120
        if !det.ingest([procSample(pid: 100, name: "tsserver", mb: mb, at: t)]).isEmpty {
            fired = true
            break
        }
        t += 30
    }
    expect(fired, "anomaly: fires during 400MB→2.8GB ramp")
}

do {
    // Large but stable process never fires.
    let det = AnomalyDetector()
    var t = 0.0
    for _ in 0..<100 {
        det.ingest([procSample(pid: 200, name: "Chrome", mb: 12_000, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "anomaly: stable 12GB process never fires")
}

do {
    // High ratio but small absolute growth (<300 MB) never fires.
    let det = AnomalyDetector()
    var t = 0.0
    for _ in 0..<30 {
        det.ingest([procSample(pid: 300, name: "tiny", mb: 50, at: t)])
        t += 30
    }
    for _ in 0..<20 {
        det.ingest([procSample(pid: 300, name: "tiny", mb: 200, at: t)])
        t += 30
    }
    expect(det.active().isEmpty, "anomaly: +150MB at 4x ratio stays quiet")
}

// MARK: - EWMA

do {
    var e = EWMA(halfLife: 60)
    e.add(0, at: 0)
    for i in 1...20 { e.add(100, at: Double(i) * 60) }
    expect(e.value! > 99, "ewma: converges toward new level")

    var h = EWMA(halfLife: 60)
    h.add(0, at: 0)
    h.add(100, at: 60)
    expect(approx(h.value!, 50, tolerance: 1), "ewma: one half-life moves half the distance")
}

// MARK: - Database round-trip (temp file)

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("memagent-selftest-\(getpid()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let db = try Database(path: tmp.path)
    var snap = try SystemStats.sample()
    snap.availBytes = 12_345_678
    try db.insert(system: snap)
    let series = try db.systemAvailSeries(since: snap.ts - 1)
    expect(series.count == 1 && series[0].avail == 12_345_678, "db: system sample round-trips")

    let p = ProcessSample(ts: snap.ts, pid: 4242, name: "selftest-proc",
                          footprintBytes: 777, residentBytes: 555, cpuTime: 1, source: "rusage")
    try db.insert(processes: [p])
    let hist = try db.processHistory(pid: 4242, since: snap.ts - 1)
    expect(hist.count == 1 && hist[0].footprintBytes == 777 && hist[0].name == "selftest-proc",
           "db: process sample round-trips")
} catch {
    expect(false, "db: unexpected error \(error)")
}

// MARK: - Live sensor sanity (this machine)

do {
    let snap = try SystemStats.sample()
    expect(snap.totalBytes > 4 * UInt64(gb), "sensors: total memory > 4 GB")
    expect(snap.availBytes > 0 && snap.availBytes < snap.totalBytes, "sensors: avail within range")
    expect([1, 2, 4].contains(snap.pressureLevel), "sensors: pressure level is 1/2/4")

    let sweep = ProcessStats.sweep()
    expect(sweep.samples.count > 50, "sensors: sees >50 processes (got \(sweep.samples.count))")
    expect(sweep.rusageCount > 10, "sensors: rusage works for >10 processes (got \(sweep.rusageCount))")
    let selfSample = sweep.samples.first { $0.pid == getpid() }
    expect(selfSample != nil && selfSample!.footprintBytes > 1_000_000,
           "sensors: sees its own footprint")
} catch {
    expect(false, "sensors: unexpected error \(error)")
}

// MARK: - Validator decision table (the Phase D safety core)

do {
    var policy = Policy.default
    policy.manageable = ["ollama", "idle-helper"]
    policy.autonomy = "suggest"

    let context = ValidationContext(
        frontmostAppName: "Cursor",
        idleSeconds: [100: 300, 200: 300, 300: 10, 400: 300, 500: 300, 600: 300, 800: 300],
        liveNames: [100: "ollama", 200: "Terminal", 300: "idle-helper",
                    400: "Cursor", 500: "random-app", 600: "idle-helper", 800: "ollama"],
        dockerAvailable: false,
        suspendedPids: [800])

    func act(_ action: String = "sigstop_process", pid: Int32, name: String) -> ProposedAction {
        ProposedAction(action: action, targetPid: pid, targetName: name, reason: "test")
    }

    func verdict(_ a: ProposedAction, _ p: Policy = policy) -> ActionVerdict {
        Validator.validate([a], policy: p, context: context)[0]
    }

    expect(verdict(act(pid: 100, name: "ollama")).allowed,
           "validator: idle manageable process is allowed")
    expect(!verdict(act(pid: 200, name: "Terminal")).allowed,
           "validator: protected app denied")
    expect(!verdict(act(pid: 300, name: "idle-helper")).allowed,
           "validator: insufficient idle denied")
    expect(!verdict(act(pid: 400, name: "Cursor")).allowed,
           "validator: frontmost app denied")
    expect(!verdict(act(pid: 500, name: "random-app")).allowed,
           "validator: not-in-allowlist denied")
    expect(!verdict(act(pid: 999, name: "ollama")).allowed,
           "validator: dead pid denied")
    expect(!verdict(act(pid: 100, name: "not-ollama")).allowed,
           "validator: pid/name mismatch denied (pid reuse guard)")
    expect(!verdict(act("docker_pause", pid: 100, name: "ollama")).allowed,
           "validator: docker action denied when docker CLI absent")
    expect(!verdict(act("rm_rf", pid: 100, name: "ollama")).allowed,
           "validator: unknown action denied")
    expect(!verdict(act(pid: 800, name: "ollama")).allowed,
           "validator: already-suspended pid denied")
    expect(verdict(ProposedAction(action: "report", targetPid: 0, targetName: "Chrome",
                                  reason: "info")).allowed,
           "validator: report is always allowed")

    var offPolicy = policy
    offPolicy.autonomy = "off"
    expect(!verdict(act(pid: 100, name: "ollama"), offPolicy).allowed,
           "validator: autonomy off denies everything but report")

    // Cap: 3 identical legal actions + 1 over the cap of 3.
    var capPolicy = policy
    capPolicy.maxActionsPerEscalation = 2
    let many = [act(pid: 100, name: "ollama"), act(pid: 600, name: "idle-helper"),
                act(pid: 100, name: "ollama")]
    let verdicts = Validator.validate(many, policy: capPolicy, context: context)
    expect(verdicts.filter(\.allowed).count == 2,
           "validator: per-escalation action cap enforced")

    // Pattern protection.
    var patternPolicy = policy
    patternPolicy.manageable = ["Chrome Helper (GPU) thing"]
    patternPolicy.protectedPatterns = ["*Helper (GPU)*"]
    let patCtx = ValidationContext(frontmostAppName: nil, idleSeconds: [700: 300],
                                   liveNames: [700: "Chrome Helper (GPU) thing"],
                                   dockerAvailable: false)
    expect(!Validator.validate([act(pid: 700, name: "Chrome Helper (GPU) thing")],
                               policy: patternPolicy, context: patCtx)[0].allowed,
           "validator: glob pattern protection wins over allowlist")
}

// MARK: - Escalation plan parsing

do {
    let clean = """
    {"analysis": "chrome is huge", "confidence": "high", "plan": [{"action": "sigstop_process", "target_pid": 42, "target_name": "ollama", "reason": "idle", "expected_mb_freed": 800}]}
    """
    let p1 = EscalationPlan.parse(fromModelOutput: clean)
    expect(p1?.plan.count == 1 && p1?.plan[0].targetPid == 42 && p1?.plan[0].expectedMbFreed == 800,
           "escalation parse: clean JSON")

    let fenced = "Here is my plan:\n```json\n\(clean)\n```\nHope that helps!"
    expect(EscalationPlan.parse(fromModelOutput: fenced)?.plan.count == 1,
           "escalation parse: JSON inside prose + code fences")

    expect(EscalationPlan.parse(fromModelOutput: "I cannot help with that.") == nil,
           "escalation parse: no JSON → nil")
    expect(EscalationPlan.parse(fromModelOutput: "{\"analysis\": \"x\"}") == nil,
           "escalation parse: missing required keys → nil")

    let emptyPlan = "{\"analysis\": \"all quiet\", \"confidence\": \"low\", \"plan\": []}"
    expect(EscalationPlan.parse(fromModelOutput: emptyPlan)?.plan.isEmpty == true,
           "escalation parse: empty plan is valid")
}

// MARK: - Rate limiter + circuit breaker

do {
    var rl = RateLimiter()
    let t0 = 1000.0
    expect(rl.allow(now: t0, minIntervalSeconds: 900, maxPerHour: 3), "ratelimit: first allowed")
    rl.record(now: t0)
    expect(!rl.allow(now: t0 + 600, minIntervalSeconds: 900, maxPerHour: 3),
           "ratelimit: blocked inside min interval")
    expect(rl.allow(now: t0 + 901, minIntervalSeconds: 900, maxPerHour: 3),
           "ratelimit: allowed after min interval")
    rl.record(now: t0 + 901)
    rl.record(now: t0 + 1802)
    expect(!rl.allow(now: t0 + 2703, minIntervalSeconds: 900, maxPerHour: 3),
           "ratelimit: hourly budget enforced")
    expect(rl.allow(now: t0 + 5000, minIntervalSeconds: 900, maxPerHour: 3),
           "ratelimit: budget window slides")

    var breaker = RateLimiter()
    breaker.recordFailure(now: t0)
    breaker.recordFailure(now: t0 + 1)
    expect(breaker.allow(now: t0 + 2, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: still closed under threshold")
    breaker.recordFailure(now: t0 + 3)
    expect(!breaker.allow(now: t0 + 4, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: opens after 3 consecutive failures")
    expect(breaker.allow(now: t0 + 3 + 3601, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: closes after cooldown")

    var recovered = RateLimiter()
    recovered.recordFailure(now: t0)
    recovered.recordFailure(now: t0 + 1)
    recovered.recordSuccess()
    recovered.recordFailure(now: t0 + 2)
    expect(recovered.allow(now: t0 + 3, minIntervalSeconds: 0, maxPerHour: 100),
           "breaker: success resets the failure count")
}

// MARK: - Chrome bridge + chrome_discard_tabs validation

do {
    let now = 1_000_000.0
    func tab(_ id: Int, active: Bool = false, audible: Bool = false, pinned: Bool = false,
             discarded: Bool = false, idleMinutes: Double = 30) -> ChromeTab {
        ChromeTab(id: id, active: active, audible: audible, pinned: pinned,
                  discarded: discarded, lastAccessed: (now - idleMinutes * 60) * 1000,
                  urlHost: "example.com", title: "t\(id)")
    }

    let bridge = ChromeBridge()
    expect(!bridge.connected(at: now), "chrome: not connected before first sync")
    _ = bridge.sync(tabs: [
        tab(1), tab(2, active: true), tab(3, audible: true), tab(4, pinned: true),
        tab(5, discarded: true), tab(6, idleMinutes: 2), tab(7),
    ], at: now)
    expect(bridge.connected(at: now + 30), "chrome: connected after sync")
    expect(!bridge.connected(at: now + 300), "chrome: sync goes stale after 90s")
    let discardable = bridge.discardable(at: now).map(\.id).sorted()
    expect(discardable == [1, 7],
           "chrome: only inactive/silent/unpinned/undiscarded/old tabs discardable, got \(discardable)")
    expect(bridge.enqueueDiscardAll(at: now) == 2, "chrome: enqueue counts discardable tabs")
    let handed = bridge.sync(tabs: [tab(1), tab(7)], at: now + 10)
    expect(handed == [1, 7], "chrome: queued discards handed to next sync, got \(handed)")
    let second = bridge.sync(tabs: [tab(1), tab(7)], at: now + 20)
    expect(second.isEmpty, "chrome: discard queue cleared after handoff")

    // Validator rules for chrome_discard_tabs.
    let chromeAction = ProposedAction(action: "chrome_discard_tabs", targetPid: 0,
                                      targetName: "Google Chrome", reason: "test")
    func ctx(connected: Bool, tabs: Int) -> ValidationContext {
        ValidationContext(frontmostAppName: "Google Chrome", idleSeconds: [:], liveNames: [:],
                          dockerAvailable: false, chromeConnected: connected,
                          chromeDiscardableTabs: tabs)
    }
    expect(Validator.validate([chromeAction], policy: .default,
                              context: ctx(connected: true, tabs: 17))[0].allowed,
           "validator: chrome discard allowed when connected with tabs (even with Chrome frontmost)")
    expect(!Validator.validate([chromeAction], policy: .default,
                               context: ctx(connected: false, tabs: 17))[0].allowed,
           "validator: chrome discard denied when extension not connected")
    expect(!Validator.validate([chromeAction], policy: .default,
                               context: ctx(connected: true, tabs: 0))[0].allowed,
           "validator: chrome discard denied with zero discardable tabs")
    var off = Policy.default
    off.autonomy = "off"
    expect(!Validator.validate([chromeAction], policy: off,
                               context: ctx(connected: true, tabs: 17))[0].allowed,
           "validator: chrome discard denied when autonomy off")
}

// MARK: - Policy round-trip / tolerant decoding

do {
    let minimal = "{\"autonomy\": \"auto_reversible\"}"
    let p = try JSON.decoder.decode(Policy.self, from: Data(minimal.utf8))
    expect(p.autonomy == "auto_reversible" && p.minIdleSeconds == 60 && !p.protected.isEmpty,
           "policy: partial file decodes with defaults filled in")
} catch {
    expect(false, "policy: tolerant decode threw \(error)")
}

print(failures == 0
      ? "OK — \(checks) checks passed"
      : "FAILED — \(failures)/\(checks) checks failed")
exit(failures == 0 ? 0 : 1)
