import Foundation

/// Damped Holt linear trend — ETS(A,Ad,N) in error-correction form.
/// Hyndman, Koehler, Ord & Snyder, "Forecasting with Exponential Smoothing:
/// The State Space Approach", Springer 2008.
///
/// The innovation scale is estimated robustly (1.4826 × EWMA of |e|) and
/// innovations are Huberized before entering the state update, so a single
/// multi-GB jump (app quit) cannot poison the level/trend. The *unclipped*
/// innovation is returned for the regime detector.
public struct HoltDamped: Codable {
    public var level: Double
    public var trend: Double        // per step
    public private(set) var madEwma: Double  // EWMA of |innovation|
    public var samples: Int = 0

    public let alpha: Double
    public let beta: Double
    public let phi: Double
    static let madLambda = 0.01
    static let huberK = 3.0

    public init(initialLevel: Double, alpha: Double = 0.15, beta: Double = 0.02,
                phi: Double = 0.97, initialScale: Double = 0) {
        self.level = initialLevel
        self.trend = 0
        self.madEwma = initialScale
        self.alpha = alpha
        self.beta = beta
        self.phi = phi
    }

    /// Robust innovation standard deviation (Gaussian-consistent MAD scaling).
    public var sigma: Double { 1.4826 * madEwma }

    /// One-step update. Returns the unclipped innovation.
    @discardableResult
    public mutating func update(_ y: Double) -> Double {
        let predicted = level + phi * trend
        let e = y - predicted
        // Robust scale first (with a floor so the clip is meaningful early on).
        if madEwma == 0 { madEwma = max(abs(e), 1) }
        madEwma += Self.madLambda * (abs(e) - madEwma)
        let clip = Self.huberK * sigma
        let eClipped = max(-clip, min(clip, e))
        level = predicted + alpha * eClipped
        trend = phi * trend + beta * eClipped
        samples += 1
        return e
    }

    /// h-step point forecast: l + φ(1−φ^h)/(1−φ)·b.
    public func forecast(steps h: Int) -> Double {
        guard h > 0 else { return level }
        let phiSum = phi * (1 - pow(phi, Double(h))) / (1 - phi)
        return level + phiSum * trend
    }

    /// Re-seed after a regime shift: trust the current level, adopt the given
    /// trend estimate, and widen the scale so the band reflects fresh doubt.
    public mutating func reseed(level: Double, trend: Double) {
        self.level = level
        self.trend = trend
        madEwma *= 2  // sigma² × 4
    }

    // MARK: - First-passage Monte Carlo

    /// Simulate forecast sample paths and record when each first crosses below
    /// `threshold`. Deterministic per (state, seed). Returns step indices.
    public func firstPassage(threshold: Double, paths: Int = 200, horizon: Int = 90,
                             seed: UInt64 = 42) -> (p10Steps: Int?, medianSteps: Int?,
                                                    pWithin: Double) {
        guard samples >= 4, sigma > 0 else { return (nil, nil, 0) }
        var rng = SplitMix64(seed: seed ^ UInt64(bitPattern: Int64(level)) &+ UInt64(samples))
        var crossings: [Int] = []
        let s = sigma
        for _ in 0..<paths {
            var l = level, b = trend
            var crossed = false
            for h in 1...horizon {
                let eps = rng.nextGaussian() * s
                let predicted = l + phi * b
                l = predicted + alpha * eps
                b = phi * b + beta * eps
                if predicted + eps <= threshold {
                    crossings.append(h)
                    crossed = true
                    break
                }
            }
            if !crossed { crossings.append(Int.max) }
        }
        crossings.sort()
        let pWithin = Double(crossings.filter { $0 <= horizon }.count) / Double(paths)
        func pct(_ p: Double) -> Int? {
            let v = crossings[Int(p * Double(paths - 1))]
            return v == Int.max ? nil : v
        }
        return (pct(0.10), pct(0.50), pWithin)
    }
}

/// Tiny deterministic PRNG (SplitMix64) + Box-Muller normal, so Monte-Carlo
/// results are reproducible and we stay clear of system entropy in a daemon.
public struct SplitMix64 {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    public mutating func nextGaussian() -> Double {
        if let s = spare {
            spare = nil
            return s
        }
        var u1 = nextUniform()
        if u1 < 1e-12 { u1 = 1e-12 }
        let u2 = nextUniform()
        let r = (-2 * log(u1)).squareRoot()
        spare = r * sin(2 * .pi * u2)
        return r * cos(2 * .pi * u2)
    }
}
