import Foundation

/// v0.3 leak engine, replacing the short/long EWMA-ratio detector.
///
/// Pipeline per watched process (PrecogMF, arXiv:2106.08938, F1 0.857 vs
/// 0.568 for plain regression; Garg et al. ISSRE'98; Matias et al. ISSRE-W'13
/// on Mann-Kendall false positives; Google far-memory warmup gate,
/// ASPLOS 2019; Autopilot per-app baselines):
///
///   1. warmup gate — nothing is judged for its first 15 min,
///   2. Theil-Sen slope (robust median of pairwise slopes) over a 30-min
///      window of 30s samples,
///   3. Mann-Kendall significance at α=0.01 with Benjamini-Hochberg
///      correction across all processes, sustained 3 consecutive
///      evaluations (5 min apart),
///   4. deceleration test — second-half slope < 0.5 × first-half slope means
///      a warming cache, not a leak,
///   5. personalized ceiling — footprint must exceed
///      max(P98 × 1.15, weekly peak) of THIS app's own decayed history
///      (with a 200 MB absolute floor); the histogram is frozen while the
///      app is flagged, so a leak can't train its own baseline.
public final class LeakDetector {
    public static let warmupSeconds = 900.0
    public static let windowSeconds = 1800.0
    public static let evalInterval = 300.0
    public static let sustainedEvals = 3
    public static let fdrQ = 0.01
    public static let absoluteFloor = 200.0 * 1_048_576

    struct AppBaseline: Codable {
        var hist = DecayedHistogram(firstBucket: 8 * 1_048_576, ratio: 1.05,
                                    buckets: 190, halfLife: 48 * 3600)
        var hourlyPeaks = [Double](repeating: 0, count: 168)
        var lastHourSlot = -1
    }

    struct ProcState {
        var name: String
        var firstSeen: Double
        var samples: [(t: Double, fp: Double)] = []
        var lastEval = 0.0
        var mkStreak = 0
        var flagged: Anomaly?
    }

    private var procs: [Int32: ProcState] = [:]
    var baselines: [String: AppBaseline] = [:]

    public init() {}

    // MARK: - Baseline persistence

    public func baselinesJSON() throws -> String {
        String(data: try JSON.encoder.encode(baselines), encoding: .utf8)!
    }

    public func loadBaselines(json: String) {
        if let decoded = try? JSON.decoder.decode([String: AppBaseline].self,
                                                  from: Data(json.utf8)) {
            baselines = decoded
        }
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(_ samples: [ProcessSample]) -> [Anomaly] {
        guard let now = samples.map(\.ts).max() else { return active() }

        for s in samples {
            var st = procs[s.pid] ?? ProcState(name: s.name, firstSeen: s.ts)
            st.name = s.name
            st.samples.append((s.ts, Double(s.footprintBytes)))
            let cutoff = s.ts - Self.windowSeconds
            st.samples.removeAll { $0.t < cutoff }
            procs[s.pid] = st

            // Baseline learns unless the app is flagged OR already under
            // suspicion (a positive MK streak) — a leak in progress must not
            // train its own baseline upward.
            if st.flagged == nil, st.mkStreak == 0 {
                var base = baselines[s.name] ?? AppBaseline()
                base.hist.add(Double(s.footprintBytes), at: s.ts)
                let slot = Int(s.ts / 3600) % 168
                if slot != base.lastHourSlot {
                    base.hourlyPeaks[slot] = 0
                    base.lastHourSlot = slot
                }
                base.hourlyPeaks[slot] = max(base.hourlyPeaks[slot], Double(s.footprintBytes))
                baselines[s.name] = base
            }
        }
        procs = procs.filter { now - ($0.value.samples.last?.t ?? 0) < 600 }

        // Evaluation round: gather candidates due for a check, test together
        // so Benjamini-Hochberg can correct across them.
        var candidates: [(pid: Int32, z: Double, p: Double)] = []
        for (pid, st) in procs {
            guard now - st.firstSeen > Self.warmupSeconds,
                  now - st.lastEval > Self.evalInterval,
                  st.samples.count >= 20 else { continue }
            procs[pid]?.lastEval = now
            let values = st.samples.map(\.fp)
            let z = Self.mannKendallZ(values)
            guard z > 0 else {
                procs[pid]?.mkStreak = 0
                procs[pid]?.flagged = nil
                continue
            }
            candidates.append((pid, z, Self.pValue(z: z)))
        }
        let significant = Self.benjaminiHochberg(candidates.map(\.p), q: Self.fdrQ)

        for (i, cand) in candidates.enumerated() {
            guard var st = procs[cand.pid] else { continue }
            defer { procs[cand.pid] = st }
            guard significant[i] else {
                st.mkStreak = 0
                st.flagged = nil
                continue
            }
            // Deceleration = cache warming, not a leak.
            let slope = Self.theilSen(st.samples)
            let mid = st.samples.count / 2
            let firstHalf = Self.theilSen(Array(st.samples[..<mid]))
            let secondHalf = Self.theilSen(Array(st.samples[mid...]))
            guard slope > 0, firstHalf <= 0 || secondHalf >= 0.5 * firstHalf else {
                st.mkStreak = 0
                st.flagged = nil
                continue
            }
            st.mkStreak += 1
            guard st.mkStreak >= Self.sustainedEvals else { continue }

            let footprint = st.samples.last?.fp ?? 0
            let ceiling = ceilingBytes(name: st.name, excludingHourOf: now)
            guard footprint > max(ceiling, Self.absoluteFloor) else {
                st.flagged = nil
                continue
            }
            st.flagged = Anomaly(
                pid: cand.pid, name: st.name,
                footprintBytes: UInt64(footprint),
                slopeMbPerHour: slope * 3600 / 1_048_576,
                ceilingBytes: UInt64(ceiling),
                tteHours: nil,  // filled by the engine, which knows avail
                sustainedMinutes: Double(st.mkStreak) * Self.evalInterval / 60,
                confidence: cand.z > 3.29 ? "high" : "medium")
        }
        return active()
    }

    public func active() -> [Anomaly] {
        procs.values.compactMap(\.flagged).sorted { $0.slopeMbPerHour > $1.slopeMbPerHour }
    }

    /// The learned "normal ceiling": max(P98 × 1.15, weekly peak). The current
    /// hour's peak is excluded — an in-progress leak IS the current hour, and
    /// must not raise the bar it is judged against.
    public func ceilingBytes(name: String, excludingHourOf now: Double? = nil) -> Double {
        guard let base = baselines[name] else { return Self.absoluteFloor }
        let p98 = base.hist.percentile(0.98) ?? 0
        var peaks = base.hourlyPeaks
        if let now {
            peaks[Int(now / 3600) % 168] = 0
        }
        let weeklyPeak = peaks.max() ?? 0
        return max(p98 * 1.15, weeklyPeak, Self.absoluteFloor)
    }

    // MARK: - Statistics (pure, exposed for selftest)

    /// Theil-Sen estimator: median of all pairwise slopes (bytes/second).
    public static func theilSen(_ samples: [(t: Double, fp: Double)]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var slopes: [Double] = []
        slopes.reserveCapacity(samples.count * (samples.count - 1) / 2)
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count where samples[j].t > samples[i].t {
                slopes.append((samples[j].fp - samples[i].fp) / (samples[j].t - samples[i].t))
            }
        }
        guard !slopes.isEmpty else { return 0 }
        slopes.sort()
        return slopes[slopes.count / 2]
    }

    /// Mann-Kendall Z statistic for a monotonic upward trend.
    public static func mannKendallZ(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 8 else { return 0 }
        var s = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                s += values[j] > values[i] ? 1 : (values[j] < values[i] ? -1 : 0)
            }
        }
        let variance = Double(n * (n - 1) * (2 * n + 5)) / 18
        guard variance > 0 else { return 0 }
        if s > 0 { return (Double(s) - 1) / variance.squareRoot() }
        if s < 0 { return (Double(s) + 1) / variance.squareRoot() }
        return 0
    }

    /// One-sided p-value from a standard normal Z (complementary CDF).
    public static func pValue(z: Double) -> Double {
        0.5 * erfc(z / 2.0.squareRoot())
    }

    /// Benjamini-Hochberg: returns, per input p-value, whether it survives
    /// FDR control at level q.
    public static func benjaminiHochberg(_ pValues: [Double], q: Double) -> [Bool] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var maxK = -1
        for (rank, idx) in order.enumerated() where
            pValues[idx] <= Double(rank + 1) / Double(m) * q {
            maxK = rank
        }
        var result = [Bool](repeating: false, count: m)
        if maxK >= 0 {
            for rank in 0...maxK { result[order[rank]] = true }
        }
        return result
    }
}
