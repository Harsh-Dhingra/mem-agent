import Foundation

/// Exponentially-decayed histogram with exponentially-spaced buckets — the
/// Autopilot/Kubernetes-VPA recommender structure (Rzadca et al., EuroSys
/// 2020; VPA uses bucket ratio 1.05, half-life 24h; Autopilot memory uses
/// t½ = 48h).
///
/// Decay is implemented by *growing* the weight of new samples
/// (w = 2^{(t−t₀)/t½}) instead of decaying every bucket, with periodic
/// renormalization — O(1) per sample.
public struct DecayedHistogram: Codable {
    public private(set) var weights: [Double]
    public private(set) var totalWeight: Double
    private var refTime: Double
    public let firstBucket: Double
    public let ratio: Double
    public let halfLife: Double

    public init(firstBucket: Double = 10 * 1_048_576, ratio: Double = 1.05,
                buckets: Int = 220, halfLife: Double = 48 * 3600) {
        self.weights = [Double](repeating: 0, count: buckets)
        self.totalWeight = 0
        self.refTime = 0
        self.firstBucket = firstBucket
        self.ratio = ratio
        self.halfLife = halfLife
    }

    public var isEmpty: Bool { totalWeight <= 0 }

    func bucketIndex(_ value: Double) -> Int {
        guard value > firstBucket else { return 0 }
        let idx = Int(log(value / firstBucket) / log(ratio))
        return min(max(idx, 0), weights.count - 1)
    }

    func bucketValue(_ index: Int) -> Double {
        firstBucket * pow(ratio, Double(index))
    }

    public mutating func add(_ value: Double, at t: Double) {
        if refTime == 0 { refTime = t }
        let w = pow(2, (t - refTime) / halfLife)
        weights[bucketIndex(value)] += w
        totalWeight += w
        if w > 1e12 {
            for i in weights.indices { weights[i] /= w }
            totalWeight /= w
            refTime = t
        }
    }

    /// Weighted percentile (p in 0...1) of the decayed distribution.
    public func percentile(_ p: Double) -> Double? {
        guard totalWeight > 0 else { return nil }
        let target = p * totalWeight
        var cum = 0.0
        for (i, w) in weights.enumerated() {
            cum += w
            if cum >= target { return bucketValue(i) }
        }
        return bucketValue(weights.count - 1)
    }
}
