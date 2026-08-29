import Foundation

/// The v0.3 prediction engine. Three separated roles the literature insists on
/// (Autopilot, TMO, oomd all keep them apart):
///   - a predictor: damped Holt ETS(A,Ad,N) with robust scale,
///   - a regime detector: two-sided Page-Hinkley on the derivative, which
///     RESETS the predictor when the world changes,
///   - a learned threshold: Autopilot-style decayed histogram of the 5-min
///     minimum of available memory, so "critical" is what THIS machine's
///     lived history says, not a hardcoded fraction.
///
/// Output is a first-passage distribution (Monte Carlo over forecast paths):
/// a calibrated P(pressure within 15 min) plus p10/median ETAs — an honest
/// band instead of a point guess.
public final class PredictionEngine {
    public static let stepSeconds = 10.0
    public static let horizonSteps = 90          // 15 minutes
    public static let gapSeconds = 60.0          // sleep/wake discontinuity
    public static let histogramWindow = 300.0    // 5-min MIN(avail) per Autopilot memory rule

    private(set) var holt: HoltDamped?
    private var ph = PageHinkley()
    private var lastSample: (t: Double, avail: Double)?
    private var recentDys: [Double] = []
    private var regimeShiftAt: Double?
    public private(set) var regimeShiftCount = 0

    public var availHistogram: DecayedHistogram
    private var windowMin = Double.infinity
    private var windowStart = 0.0

    public init(histogram: DecayedHistogram? = nil) {
        availHistogram = histogram ?? DecayedHistogram()
    }

    // MARK: - Ingest

    public func observe(t: Double, avail: Double) {
        defer { lastSample = (t, avail) }

        // 5-min window minimum → learned-threshold histogram.
        if windowStart == 0 { windowStart = t }
        windowMin = min(windowMin, avail)
        if t - windowStart >= Self.histogramWindow {
            availHistogram.add(windowMin, at: t)
            windowStart = t
            windowMin = avail
        }

        guard let last = lastSample else {
            holt = HoltDamped(initialLevel: avail)
            return
        }
        let dt = t - last.t
        if dt > Self.gapSeconds || dt <= 0 {
            // Sleep/wake or clock jump: re-anchor, don't fabricate a derivative.
            holt?.level = avail
            holt?.trend = 0
            recentDys.removeAll()
            return
        }

        let dy = avail - last.avail
        recentDys.append(dy)
        if recentDys.count > 6 { recentDys.removeFirst() }

        holt?.update(avail)
        if ph.observe(dy) != .none {
            let freshTrend = recentDys.reduce(0, +) / Double(max(1, recentDys.count))
            holt?.reseed(level: avail, trend: freshTrend)
            regimeShiftAt = t
            regimeShiftCount += 1
        }
    }

    // MARK: - Thresholds (learned)

    public func thresholds(totalBytes: Double) -> (warn: Double, critical: Double) {
        let floorCritical = 0.05 * totalBytes
        // Learned θ = p5 of lived 5-min minima — but capped at half the median
        // so a machine that has never felt pressure doesn't set θ at its own
        // normal operating level and alarm on flat traffic.
        let p5 = availHistogram.percentile(0.05) ?? floorCritical
        let p50 = availHistogram.percentile(0.50) ?? totalBytes
        let critical = max(floorCritical, min(p5, 0.5 * p50))
        var warn = min(max(min(availHistogram.percentile(0.25) ?? 2 * critical, 0.75 * p50),
                           1.5 * critical),
                       0.25 * totalBytes)
        warn = max(warn, 1.1 * critical)  // ordering survives the cap
        return (warn, critical)
    }

    // MARK: - Query

    public func predict(totalBytes: Double,
                        swapInRatePagesPerSec: Double,
                        drivers: [String],
                        now: Double = Date().timeIntervalSince1970) -> Prediction {
        let avail = lastSample?.avail ?? 0
        var out = Prediction(availBytes: UInt64(max(0, avail)),
                             swapInRatePagesPerSec: swapInRatePagesPerSec,
                             drivers: drivers)
        out.regimeShiftRecent = regimeShiftAt.map { now - $0 < 120 } ?? false

        guard let holt, holt.samples >= 4 else { return out }
        let (thetaWarn, thetaCritical) = thresholds(totalBytes: totalBytes)
        out.thetaCriticalBytes = UInt64(max(0, thetaCritical))
        out.slopeBytesPerSec = holt.trend / Self.stepSeconds

        let relNoise = holt.sigma / max(1, abs(holt.trend))
        out.confidence = relNoise < 0.5 ? "high" : (relNoise < 1.5 ? "medium" : "low")

        let fp = holt.firstPassage(threshold: thetaCritical,
                                   paths: 200, horizon: Self.horizonSteps)
        out.pPressure15min = fp.pWithin
        out.etaP10Minutes = fp.p10Steps.map { Double($0) * Self.stepSeconds / 60 }
        out.etaMinutesToCritical = fp.medianSteps.map { Double($0) * Self.stepSeconds / 60 }

        // Warn ETA from the point forecast (cheap scan).
        if avail > thetaWarn {
            for h in 1...Self.horizonSteps where holt.forecast(steps: h) <= thetaWarn {
                out.etaMinutesToWarn = Double(h) * Self.stepSeconds / 60
                break
            }
        } else {
            out.etaMinutesToWarn = 0
        }
        return out
    }
}
