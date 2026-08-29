import Foundation

/// The v0.2 predictor (single EWMA of the derivative with a variance gate).
/// Kept verbatim so `memagent backtest` can compare the new engine against it
/// on the same recorded trace.
public enum LegacyPredictor {
    public static let slopeHalfLife = 300.0
    public static let warnFraction = 0.10
    public static let criticalFraction = 0.05

    public static func predict(samples: [(t: Double, avail: Double)],
                               totalBytes: Double,
                               swapInRatePagesPerSec: Double = 0,
                               drivers: [String] = []) -> Prediction {
        let availNow = samples.last?.avail ?? 0
        var out = Prediction(availBytes: UInt64(max(0, availNow)),
                             swapInRatePagesPerSec: swapInRatePagesPerSec,
                             drivers: drivers)
        guard samples.count >= 4 else { return out }

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
        out.confidence = relNoise < 0.5 ? "high" : (relNoise < 1.5 ? "medium" : "low")

        guard slope < 0, out.confidence != "low" else { return out }
        let warnAt = totalBytes * warnFraction
        let criticalAt = totalBytes * criticalFraction
        func eta(to threshold: Double) -> Double? {
            guard availNow > threshold else { return 0 }
            let seconds = (availNow - threshold) / -slope
            guard seconds < 24 * 3600 else { return nil }
            return seconds / 60
        }
        out.etaMinutesToWarn = eta(to: warnAt)
        out.etaMinutesToCritical = eta(to: criticalAt)
        return out
    }
}
