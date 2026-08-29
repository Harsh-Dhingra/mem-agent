import Foundation

/// Thrash gauge synthesized from vm_statistics64 counter deltas — a macOS
/// stand-in for Linux PSI (Weiner, kernel 4.20), which drives all of Meta's
/// reclaim (TMO, ASPLOS 2022; systemd-oomd's 60%/30s kill rule).
///
/// The core discriminations, from Denning's thrashing theory (CACM 1968) and
/// Meta practice:
///   - swap-OUTS alone are healthy offloading (Senpai deliberately induces
///     them) — never alarm on them;
///   - swap-INS are the damage signal: reading back what was just written out
///     is pure wasted work;
///   - churn = balanced in/out traffic is the classic thrash signature.
///
/// Used as a GATE on actuation, not as a predictor: a forecast without
/// corroborating measured pain should only trigger cheap reversible actions.
public struct PressureGauge: Codable {
    // Per-event service costs (µs/page) to convert events into lost time.
    // Defaults are mid-range for Apple Silicon + NVMe; the relative signal is
    // what matters until locally calibrated.
    public static let tDecompUs = 2.0
    public static let tSwapinUs = 100.0
    public static let tPageinUs = 100.0

    /// PSI's own decay constants at our 10s period: α_W = 1 − exp(−10/W).
    static let a10 = 1 - exp(-10.0 / 10.0)
    static let a60 = 1 - exp(-10.0 / 60.0)

    public private(set) var avg10 = 0.0
    public private(set) var avg60 = 0.0
    public private(set) var lastInstant = 0.0
    private var last: (t: Double, swapIns: UInt64, swapOuts: UInt64,
                       pageIns: UInt64, compressions: UInt64, decompressions: UInt64)? = nil

    // Only the smoothed averages persist across restarts.
    enum CodingKeys: String, CodingKey {
        case avg10, avg60, lastInstant
    }

    public init() {}

    /// Feed one system snapshot; counters are cumulative since boot.
    public mutating func observe(_ s: SystemSnapshot, ncpu: Int) {
        // vm_statistics64 has no decompressions field surfaced in our snapshot;
        // compressions covers the compressor-churn half we track.
        defer {
            last = (s.ts, s.swapIns, s.swapOuts, s.pageIns, s.compressions, 0)
        }
        guard let last, s.ts > last.t else { return }
        let dt = s.ts - last.t
        if dt > 60 {
            // Sleep/wake gap: backfill with zeros (PSI's calc_load_n behavior)
            // so a resuming laptop doesn't report phantom pressure.
            let missed = Int(dt / 10)
            for _ in 0..<min(missed, 60) {
                avg10 += Self.a10 * (0 - avg10)
                avg60 += Self.a60 * (0 - avg60)
            }
            return
        }

        let dSwapIn = Double(s.swapIns &- min(s.swapIns, last.swapIns))
        let dSwapOut = Double(s.swapOuts &- min(s.swapOuts, last.swapOuts))
        let dPageIn = Double(s.pageIns &- min(s.pageIns, last.pageIns))
        let dComp = Double(s.compressions &- min(s.compressions, last.compressions))

        // (1) Hard-thrash churn: balanced swap in/out = wasted round-trips.
        let swapTraffic = dSwapIn + dSwapOut
        let churn = swapTraffic > 0 ? min(dSwapIn, dSwapOut) / swapTraffic : 0

        // (2) Paging duty cycle (Denning's 50% rule: >0.5 is the collapse regime).
        let stallUs = dSwapIn * Self.tSwapinUs + dPageIn * Self.tPageinUs
        let duty = stallUs / (dt * 1e6 * Double(max(1, ncpu)))

        // (3) Compressor churn proxy: heavy compression traffic while swapping in.
        let compTraffic = dComp + dSwapIn
        let compChurn = compTraffic > 0 ? min(dComp, dSwapIn) / compTraffic : 0

        var index = 0.4 * churn + 0.4 * min(duty / 0.5, 1) + 0.2 * compChurn
        // Swap-outs alone (offloading) must not alarm.
        if dSwapIn == 0 { index = min(index, 0.05) }
        index = min(max(index, 0), 1)

        lastInstant = index
        avg10 += Self.a10 * (index - avg10)
        avg60 += Self.a60 * (index - avg60)
    }

    /// Severity ladder for reporting.
    public var label: String {
        switch avg10 {
        case ..<0.1: return "healthy"
        case ..<0.3: return "offloading"
        case ..<0.6: return "thrashing"
        default: return "collapse"
        }
    }
}
