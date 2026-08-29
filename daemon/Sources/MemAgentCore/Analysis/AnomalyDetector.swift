import Foundation

/// Flags processes whose footprint grows abnormally: short-window EWMA
/// exceeding the long-window EWMA by both a ratio and an absolute margin,
/// sustained over several consecutive sweeps.
public final class AnomalyDetector {
    public static let shortHalfLife = 120.0    // 2 min
    public static let longHalfLife = 1800.0    // 30 min
    public static let ratioThreshold = 1.5
    public static let absoluteThresholdBytes = 300.0 * 1_048_576
    public static let sustainedSweeps = 3

    struct PidState {
        var short: EWMA
        var long: EWMA
        var sustained = 0
        var firstDetected: Double?
        var lastSeen: Double
        var name: String
        var footprint: UInt64 = 0
    }

    private var states: [Int32: PidState] = [:]

    public init() {}

    /// Feed one sweep; returns anomalies active after this sweep.
    @discardableResult
    public func ingest(_ samples: [ProcessSample]) -> [Anomaly] {
        for s in samples {
            var st = states[s.pid] ?? PidState(
                short: EWMA(halfLife: Self.shortHalfLife),
                long: EWMA(halfLife: Self.longHalfLife),
                lastSeen: s.ts, name: s.name)
            st.name = s.name
            st.lastSeen = s.ts
            st.footprint = s.footprintBytes
            st.short.add(Double(s.footprintBytes), at: s.ts)
            st.long.add(Double(s.footprintBytes), at: s.ts)

            if let short = st.short.value, let long = st.long.value,
               short > long * Self.ratioThreshold,
               short - long > Self.absoluteThresholdBytes {
                st.sustained += 1
                if st.sustained >= Self.sustainedSweeps, st.firstDetected == nil {
                    st.firstDetected = s.ts
                }
            } else {
                st.sustained = 0
                st.firstDetected = nil
            }
            states[s.pid] = st
        }

        // Drop processes not seen for 10 minutes (exited or fell out of top-N).
        if let newest = samples.map(\.ts).max() {
            states = states.filter { newest - $0.value.lastSeen < 600 }
        }
        return active()
    }

    public func active() -> [Anomaly] {
        states.compactMap { pid, st in
            guard let first = st.firstDetected,
                  let short = st.short.value, let long = st.long.value else { return nil }
            return Anomaly(
                pid: pid, name: st.name, footprintBytes: st.footprint,
                shortEwmaBytes: short, longEwmaBytes: long,
                growthBytes: short - long, firstDetectedTs: first)
        }.sorted { $0.growthBytes > $1.growthBytes }
    }
}
