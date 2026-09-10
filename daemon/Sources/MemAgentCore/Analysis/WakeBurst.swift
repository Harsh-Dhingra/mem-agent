import Foundation

/// Sleep/wake awareness. Twelve days of real laptop telemetry showed the
/// recorded trace shattered into ~500 fragments averaging seven minutes:
/// pressure episodes on a laptop happen AT WAKE — the lid opens and the
/// working set swaps back in as a storm — exactly where a trend forecaster
/// has no history. So wake gets treated as its own predicted event: a wall-
/// clock gap in the 10s sampling cadence marks the wake, and for a short
/// window afterwards the daemon escalates on direct evidence (kernel level,
/// swap-in storm) instead of waiting for slow smoothed averages to catch up.
public struct WakeBurst: Codable {
    /// A sampling gap longer than this is a sleep (the timer never lags this far).
    public static let gapSeconds = 120.0
    /// How long after wake the burst rules stay in force.
    public static let windowSeconds = 240.0
    /// Swap-in pages/s that counts as a wake storm (~16 MB/s on 16K pages).
    public static let stormPagesPerSec = 1000.0

    public private(set) var wokeAt = 0.0
    public private(set) var sleptFor = 0.0

    public init() {}

    /// Feed the gap between consecutive samples; returns true when this gap
    /// marks a wake transition.
    @discardableResult
    public mutating func observeGap(now: Double, gap: Double) -> Bool {
        guard gap > Self.gapSeconds else { return false }
        wokeAt = now
        sleptFor = gap
        return true
    }

    public func active(now: Double) -> Bool {
        wokeAt > 0 && now - wokeAt < Self.windowSeconds
    }

    /// During the wake window, escalate on direct evidence — the smoothed
    /// thrash gauge was zero-backfilled across the sleep and lags by design.
    public func shouldEscalate(now: Double, pressureLevel: Int,
                               swapInPagesPerSec: Double) -> Bool {
        active(now: now) && (pressureLevel >= 2 || swapInPagesPerSec >= Self.stormPagesPerSec)
    }
}
