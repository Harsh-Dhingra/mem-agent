import Foundation

/// Deterministic time-to-pressure estimator. No ML: EWMA of d(avail)/dt with a
/// variance gate, so an ETA is only reported for a stable downward trend.
public enum Predictor {
    public static let slopeHalfLife = 300.0        // 5 min
    public static let warnFraction = 0.10          // avail < 10% of total → warn zone
    public static let criticalFraction = 0.05

    /// `samples`: (epoch seconds, avail bytes), ordered by time.
    public static func predict(samples: [(t: Double, avail: Double)],
                               totalBytes: Double,
                               swapInRatePagesPerSec: Double = 0,
                               drivers: [String] = []) -> Prediction {
        let availNow = samples.last?.avail ?? 0
        var out = Prediction(
            etaMinutesToWarn: nil,
            etaMinutesToCritical: nil,
            confidence: "low",
            slopeBytesPerSec: 0,
            availBytes: UInt64(max(0, availNow)),
            swapInRatePagesPerSec: swapInRatePagesPerSec,
            drivers: drivers)

        guard samples.count >= 4 else { return out }

        // EWMA over pairwise derivatives, plus an EWMA of squared deviation
        // from the running mean to gate on noise.
        var slopeEwma = EWMA(halfLife: slopeHalfLife)
        var varEwma = EWMA(halfLife: slopeHalfLife)
        for i in 1..<samples.count {
            let dt = samples[i].t - samples[i - 1].t
            guard dt > 0.5 else { continue }
            let d = (samples[i].avail - samples[i - 1].avail) / dt
            let prior = slopeEwma.value ?? d
            slopeEwma.add(d, at: samples[i].t)
            let dev = d - prior
            varEwma.add(dev * dev, at: samples[i].t)
        }

        guard let slope = slopeEwma.value else { return out }
        out.slopeBytesPerSec = slope
        let std = sqrt(max(0, varEwma.value ?? 0))

        let relNoise = std / max(1, abs(slope))
        let confidence: String
        if relNoise < 0.5 { confidence = "high" }
        else if relNoise < 1.5 { confidence = "medium" }
        else { confidence = "low" }
        out.confidence = confidence

        guard slope < 0, confidence != "low" else { return out }

        let warnAt = totalBytes * warnFraction
        let criticalAt = totalBytes * criticalFraction
        func eta(to threshold: Double) -> Double? {
            guard availNow > threshold else { return 0 }
            let seconds = (availNow - threshold) / -slope
            guard seconds < 24 * 3600 else { return nil }  // beyond a day = no meaningful ETA
            return seconds / 60
        }
        out.etaMinutesToWarn = eta(to: warnAt)
        out.etaMinutesToCritical = eta(to: criticalAt)
        return out
    }
}
