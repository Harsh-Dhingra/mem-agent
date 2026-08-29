import Foundation

/// Time-aware exponentially weighted moving average.
public struct EWMA {
    public let halfLife: Double  // seconds
    public private(set) var value: Double?
    private var lastT: Double?

    public init(halfLife: Double) {
        self.halfLife = halfLife
    }

    public mutating func add(_ x: Double, at t: Double) {
        if let v = value, let lt = lastT, t > lt {
            let alpha = 1 - exp(-log(2.0) * (t - lt) / halfLife)
            value = v + alpha * (x - v)
        } else {
            value = x
        }
        lastT = t
    }
}
