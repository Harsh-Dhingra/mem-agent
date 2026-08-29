import Foundation

/// Two-sided Page-Hinkley changepoint detector on the memory derivative.
/// Page, "Continuous Inspection Schemes", Biometrika 1954; Hinkley 1971.
///
/// Asymmetric thresholds (Senpai principle — retreat fast, relax slowly):
/// the "drain accelerating" side trips at 3σ, the "pressure relieving" side
/// at 6σ. A trip means the regime changed and the Holt state should be
/// reseeded rather than left to slowly re-converge.
public struct PageHinkley: Codable {
    public enum Shift: String, Codable {
        case none, draining, relieving
    }

    public private(set) var mu = 0.0        // running mean of dy
    public private(set) var madEwma = 0.0
    private var sUp = 0.0
    private var sDown = 0.0
    private var freezeMean = 0
    public private(set) var samples = 0

    static let lambdaMean = 0.01
    static let k = 0.6        // slack, in sigmas (slightly above textbook 0.5 —
                              // the adaptive robust σ runs a touch low, which
                              // would otherwise halve the theoretical ARL₀)
    static let hDown = 5.0    // fast side: memory draining faster (ARL₀ ≈ 465 samples)
    static let hUp = 7.0      // slow side: crisis abating
    static let forgetting = 0.999

    public init() {}

    public var sigma: Double { max(1.4826 * madEwma, 1e-9) }

    public mutating func observe(_ dy: Double) -> Shift {
        samples += 1
        if madEwma == 0 { madEwma = max(abs(dy - mu), 1) }
        madEwma += Self.lambdaMean * (abs(dy - mu) - madEwma)
        if freezeMean > 0 {
            freezeMean -= 1
        } else {
            mu += Self.lambdaMean * (dy - mu)
        }
        let dev = dy - mu
        let delta = Self.k * sigma
        sUp = max(0, Self.forgetting * sUp + dev - delta)
        sDown = max(0, Self.forgetting * sDown - dev - delta)

        guard samples > 30 else { return .none }  // let mean and scale settle first
        if sDown > Self.hDown * sigma {
            reset()
            return .draining
        }
        if sUp > Self.hUp * sigma {
            reset()
            return .relieving
        }
        return .none
    }

    private mutating func reset() {
        sUp = 0
        sDown = 0
        freezeMean = 6  // post-change bias guard
    }
}
