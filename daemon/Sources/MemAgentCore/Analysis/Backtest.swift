import Foundation

/// Replays the daemon's own recorded system history through the v0.3
/// prediction engine and the v0.2 legacy predictor, and scores both against
/// what the kernel actually did (pressure_level transitions) — the
/// counterfactual-evaluation idea from Google's far-memory control loop
/// (ASPLOS 2019): judge thresholds by what they WOULD have done.
public enum Backtest {
    public struct Report {
        public var samples: Int
        public var segments: Int
        public var warnEpisodes: Int
        // New engine.
        public var alertsNew: Int
        public var truePositivesNew: Int
        public var episodesCaughtNew: Int
        public var regimeShifts: Int
        // Legacy.
        public var alertsLegacy: Int
        public var truePositivesLegacy: Int
        public var episodesCaughtLegacy: Int

        public func rendered() -> String {
            func pct(_ a: Int, _ b: Int) -> String {
                b == 0 ? "n/a" : String(format: "%.0f%%", Double(a) / Double(b) * 100)
            }
            return """
            BACKTEST — \(samples) samples in \(segments) contiguous segments
            ground truth: \(warnEpisodes) kernel warn/critical episodes

                                        v0.3 engine     v0.2 legacy
            alerts fired                \(String(alertsNew).padding(toLength: 16, withPad: " ", startingAt: 0))\(alertsLegacy)
            alert precision             \(pct(truePositivesNew, alertsNew).padding(toLength: 16, withPad: " ", startingAt: 0))\(pct(truePositivesLegacy, alertsLegacy))
            episodes anticipated        \(pct(episodesCaughtNew, warnEpisodes).padding(toLength: 16, withPad: " ", startingAt: 0))\(pct(episodesCaughtLegacy, warnEpisodes))
            regime-shift resets         \(regimeShifts)

            alert = P(critical within 15 min) ≥ 0.8 (v0.3) / ETA<15min at med+ confidence (v0.2)
            true positive = kernel reported warn/critical within the following 15 min
            episode anticipated = an alert fired in the 15 min before the episode began
            """
        }
    }

    public static func run(series: [(t: Double, avail: Double, level: Int)],
                           totalBytes: Double) -> Report {
        var report = Report(samples: series.count, segments: 0, warnEpisodes: 0,
                            alertsNew: 0, truePositivesNew: 0, episodesCaughtNew: 0,
                            regimeShifts: 0, alertsLegacy: 0, truePositivesLegacy: 0,
                            episodesCaughtLegacy: 0)
        guard series.count > 50 else { return report }

        // Ground truth: episode starts (level 1 → ≥2).
        var episodeStarts: [Double] = []
        for i in 1..<series.count where series[i].level >= 2 && series[i - 1].level < 2 {
            episodeStarts.append(series[i].t)
        }
        report.warnEpisodes = episodeStarts.count

        func pressureWithin(after t: Double, seconds: Double) -> Bool {
            // Any sample in (t, t+seconds] at warn or worse.
            series.contains { $0.t > t && $0.t <= t + seconds && $0.level >= 2 }
        }

        var alertTimesNew: [Double] = []
        var alertTimesLegacy: [Double] = []

        // Replay in contiguous segments (gaps = daemon downtime / sleep).
        let engine = PredictionEngine()
        var ring: [(t: Double, avail: Double)] = []
        var lastT = 0.0
        var evalCountdown = 0
        var lastAlertNew = 0.0
        var lastAlertLegacy = 0.0

        for sample in series {
            if sample.t - lastT > 60 {
                report.segments += 1
                ring.removeAll()
            }
            lastT = sample.t
            engine.observe(t: sample.t, avail: sample.avail)
            ring.append((sample.t, sample.avail))
            let cutoff = sample.t - 45 * 60
            ring.removeAll { $0.t < cutoff }

            // Evaluate every 3 samples (~30s) with a 5-min alert refractory
            // period per predictor so bursts count once.
            evalCountdown -= 1
            guard evalCountdown <= 0 else { continue }
            evalCountdown = 3

            let p = engine.predict(totalBytes: totalBytes, swapInRatePagesPerSec: 0,
                                   drivers: [], now: sample.t)
            if p.pPressure15min >= 0.8, sample.level < 2, sample.t - lastAlertNew > 300 {
                lastAlertNew = sample.t
                report.alertsNew += 1
                alertTimesNew.append(sample.t)
                if pressureWithin(after: sample.t, seconds: 900) {
                    report.truePositivesNew += 1
                }
            }

            let legacy = LegacyPredictor.predict(samples: ring, totalBytes: totalBytes)
            if let eta = legacy.etaMinutesToCritical, eta < 15, legacy.confidence != "low",
               sample.level < 2, sample.t - lastAlertLegacy > 300 {
                lastAlertLegacy = sample.t
                report.alertsLegacy += 1
                alertTimesLegacy.append(sample.t)
                if pressureWithin(after: sample.t, seconds: 900) {
                    report.truePositivesLegacy += 1
                }
            }
        }
        report.regimeShifts = engine.regimeShiftCount

        report.episodesCaughtNew = episodeStarts.filter { start in
            alertTimesNew.contains { $0 < start && start - $0 <= 900 }
        }.count
        report.episodesCaughtLegacy = episodeStarts.filter { start in
            alertTimesLegacy.contains { $0 < start && start - $0 <= 900 }
        }.count
        return report
    }
}
