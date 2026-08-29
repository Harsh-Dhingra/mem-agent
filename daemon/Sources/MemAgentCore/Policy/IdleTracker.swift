import Darwin
import Foundation

/// Tracks per-process CPU activity across sweeps so the validator can require
/// a target to have been idle for N seconds before it may be touched.
public final class IdleTracker {
    /// More than this much CPU inside one sweep window counts as "active".
    public static let activeThresholdNs = 100_000_000.0  // 100 ms

    private struct State {
        var cpu: UInt64          // mach time units (cumulative)
        var lastActive: Double   // epoch seconds of last observed activity
        var lastSeen: Double
    }

    private var states: [Int32: State] = [:]
    private let machToNs: Double

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        machToNs = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    public func ingest(_ samples: [ProcessSample]) {
        for s in samples {
            if var st = states[s.pid] {
                let deltaNs = Double(s.cpuTime &- min(s.cpuTime, st.cpu)) * machToNs
                if deltaNs > Self.activeThresholdNs {
                    st.lastActive = s.ts
                }
                st.cpu = s.cpuTime
                st.lastSeen = s.ts
                states[s.pid] = st
            } else {
                // First sighting: conservatively treat as active now, so a
                // brand-new process can never be "idle enough" immediately.
                states[s.pid] = State(cpu: s.cpuTime, lastActive: s.ts, lastSeen: s.ts)
            }
        }
        if let newest = samples.map(\.ts).max() {
            states = states.filter { newest - $0.value.lastSeen < 600 }
        }
    }

    public func idleSeconds(now: Double = Date().timeIntervalSince1970) -> [Int32: Double] {
        states.mapValues { max(0, now - $0.lastActive) }
    }
}
