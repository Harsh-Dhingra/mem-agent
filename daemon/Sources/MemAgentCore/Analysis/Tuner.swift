import Foundation

/// Nightly counterfactual self-tuning of the alert cutoff — the control-loop
/// idea from Google's software-defined far memory (ASPLOS 2019): judge every
/// candidate threshold by what it WOULD have done on recorded history, pick
/// the best, and clamp so a bad fit can never disable alerting entirely.
///
/// One replay of the trace records (t, p, level) at each evaluation point;
/// scoring the whole cutoff grid is then a cheap pass over that log.
public enum Tuner {
    public struct Result: Codable {
        public var cutoff: Double
        public var alerts: Int
        public var truePositives: Int
        public var episodes: Int
        public var episodesCaught: Int
        public var samples: Int
        public var fittedAt: Double
        /// Median avail at kernel normal→warn flips — the empirical line the
        /// predictor should be forecasting.
        public var kernelFlipAvail: Double?
    }

    public static let cutoffGrid: [Double] = stride(from: 0.50, through: 0.95, by: 0.05).map { $0 }
    public static let defaultCutoff = 0.8
    static let refractory = 300.0
    static let truthWindow = 900.0

    /// Fit the alert cutoff on a recorded series. Returns nil when the trace
    /// carries no ground-truth episodes to fit against (nothing to learn).
    public static func fit(series: [(t: Double, avail: Double, level: Int)],
                           totalBytes: Double,
                           now: Double = Date().timeIntervalSince1970) -> Result? {
        guard series.count > 500 else { return nil }

        var episodeStarts: [Double] = []
        var flipAvails: [Double] = []
        for i in 1..<series.count where series[i].level >= 2 && series[i - 1].level < 2 {
            episodeStarts.append(series[i].t)
            flipAvails.append(series[i].avail)
        }
        guard !episodeStarts.isEmpty else { return nil }
        let kernelFlipAvail = flipAvails.sorted()[flipAvails.count / 2]

        // Single replay: log p at each eval point where an alert is possible.
        // The replay engine predicts against the empirical kernel line — the
        // ground truth we're scoring against.
        let engine = PredictionEngine()
        engine.empiricalWarnAvail = kernelFlipAvail
        var lastT = 0.0
        var countdown = 0
        var evals: [(t: Double, p: Double)] = []
        for s in series {
            if s.t - lastT > 60 { countdown = 0 }
            lastT = s.t
            engine.observe(t: s.t, avail: s.avail)
            countdown -= 1
            guard countdown <= 0, s.level < 2 else { continue }
            countdown = 3
            let p = engine.predict(totalBytes: totalBytes, swapInRatePagesPerSec: 0,
                                   drivers: [], now: s.t)
            evals.append((s.t, p.pPressure15min))
        }

        func pressureFollows(_ t: Double) -> Bool {
            series.contains { $0.t > t && $0.t <= t + truthWindow && $0.level >= 2 }
        }

        var best: Result?
        var bestScore = -Double.infinity
        for cutoff in cutoffGrid {
            var alerts = 0, tps = 0
            var lastAlert = 0.0
            var alertTimes: [Double] = []
            for e in evals where e.p >= cutoff && e.t - lastAlert > refractory {
                lastAlert = e.t
                alerts += 1
                alertTimes.append(e.t)
                if pressureFollows(e.t) { tps += 1 }
            }
            let caught = episodeStarts.filter { start in
                alertTimes.contains { $0 < start && start - $0 <= truthWindow }
            }.count
            // Anticipating episodes is the mission; false alarms cost; a
            // higher cutoff wins ties (fewer marginal alerts).
            let score = 3.0 * Double(caught) + 1.0 * Double(tps)
                - 1.5 * Double(alerts - tps) + 0.01 * cutoff
            if score > bestScore {
                bestScore = score
                best = Result(cutoff: cutoff, alerts: alerts, truePositives: tps,
                              episodes: episodeStarts.count, episodesCaught: caught,
                              samples: series.count, fittedAt: now,
                              kernelFlipAvail: kernelFlipAvail)
            }
        }
        // Revert-to-default guard: a fit that catches nothing teaches nothing
        // about the cutoff — but the kernel flip line is still real knowledge.
        if let b = best, b.episodesCaught == 0, b.truePositives == 0 {
            return Result(cutoff: defaultCutoff, alerts: b.alerts, truePositives: 0,
                          episodes: b.episodes, episodesCaught: 0,
                          samples: b.samples, fittedAt: now,
                          kernelFlipAvail: kernelFlipAvail)
        }
        return best
    }
}
