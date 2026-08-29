import Foundation

/// Learns the user's app-usage patterns from the frontmost-app sequence and
/// answers "how likely is the user to come back to this app soon?"
///
///   P_return = 0.5·PPM + 0.3·(1 − e^{−1/reuse_distance}) + 0.2·frecency
///
/// - PPM: order-3 Prediction-by-Partial-Matching over the app-switch sequence
///   with per-order self-weighted accuracy (PREPP, UbiComp 2013 — 80.9% top-5
///   vs 48.8% for most-frequently-used; context features add only 0.5pt, so
///   none are used).
/// - reuse distance in switch events (SmartLMK, ACM TECS 2016).
/// - session frecency with a 4-hour half-life using Firefox's stored-date
///   trick (no decay sweeps ever needed).
///
/// Also tracks frontmost DWELL, because Iqbal & Horvitz (CHI 2007) showed an
/// app used for 5–30 min and left minutes ago is the WORST suspend target —
/// pure idle-time ranking gets that exactly backwards.
public final class UsageModel: Codable {
    public static let sessionHalfLife = 4.0 * 3600
    static let lambda = log(2.0) / sessionHalfLife
    static let ppmMaxOrder = 3
    static let longDwellSeconds = 300.0   // "worked in it" threshold
    static let dwellProtectWindow = 1200.0 // don't touch for 20 min after

    struct AppStats: Codable {
        var frecencyStored = 0.0        // date at which score decays to 1
        var visits = 0
        var lastFrontmostEnd = 0.0
        var lastLongDwellEnd = 0.0
        var lastSeenSwitchIndex = 0
        var reuseDistanceEwma = 0.0     // in switch events
    }

    var apps: [String: AppStats] = [:]
    var recent: [String] = []           // last few frontmost apps, newest last
    var switchIndex = 0
    var currentApp: String?
    var currentDwellStart = 0.0
    // PPM: context "a|b|c" → next-app counts; accuracy per order.
    var ppmCounts: [String: [String: Int]] = [:]
    var ppmHits: [Double]
    var ppmTotals: [Double]

    public init() {
        ppmHits = [Double](repeating: 1, count: Self.ppmMaxOrder + 1)
        ppmTotals = [Double](repeating: 2, count: Self.ppmMaxOrder + 1)
    }

    // MARK: - Observation

    /// Feed the current frontmost app name (call every ~15s).
    public func observeFrontmost(_ name: String?, at t: Double) {
        guard let name, name != currentApp else { return }

        // Close the outgoing dwell.
        if let prev = currentApp, var st = apps[prev] {
            let dwell = t - currentDwellStart
            st.lastFrontmostEnd = t
            if dwell >= Self.longDwellSeconds {
                st.lastLongDwellEnd = t
            }
            apps[prev] = st
        }

        switchIndex += 1
        var st = apps[name] ?? AppStats()

        // Reuse distance (in switch events since last seen).
        if st.lastSeenSwitchIndex > 0 {
            let dist = Double(switchIndex - st.lastSeenSwitchIndex)
            st.reuseDistanceEwma = st.reuseDistanceEwma == 0
                ? dist : st.reuseDistanceEwma + 0.2 * (dist - st.reuseDistanceEwma)
        }
        st.lastSeenSwitchIndex = switchIndex
        st.visits += 1

        // Frecency, stored-date form: score(now) = e^{λ(stored − now)}.
        let oldScore = st.frecencyStored > 0 ? exp(Self.lambda * (st.frecencyStored - t)) : 0
        let newScore = oldScore + 2.0  // explicit switch = weight 2
        st.frecencyStored = t + log(newScore) / Self.lambda
        apps[name] = st

        // PPM: score each order's prediction before updating counts.
        for order in 1...Self.ppmMaxOrder where recent.count >= order {
            let context = recent.suffix(order).joined(separator: "|")
            if let counts = ppmCounts[context], !counts.isEmpty {
                ppmTotals[order] += 1
                if counts.max(by: { $0.value < $1.value })?.key == name {
                    ppmHits[order] += 1
                }
            }
            ppmCounts[context, default: [:]][name, default: 0] += 1
        }

        recent.append(name)
        if recent.count > 8 { recent.removeFirst() }
        currentApp = name
        currentDwellStart = t
    }

    // MARK: - Queries

    /// PPM blend across orders, weighted by each order's observed accuracy.
    func pPPM(app: String) -> Double {
        var num = 0.0, den = 0.0
        for order in 1...Self.ppmMaxOrder where recent.count >= order {
            let context = recent.suffix(order).joined(separator: "|")
            guard let counts = ppmCounts[context] else { continue }
            let total = counts.values.reduce(0, +)
            guard total > 0 else { continue }
            let w = ppmHits[order] / ppmTotals[order]
            num += w * Double(counts[app] ?? 0) / Double(total)
            den += w
        }
        return den > 0 ? num / den : 0
    }

    public func pReturn(app: String, now: Double) -> Double {
        guard let st = apps[app] else { return 0.15 }  // unknown app: weak prior
        let ppm = pPPM(app: app)
        let reuse = st.reuseDistanceEwma > 0 ? 1 - exp(-1 / st.reuseDistanceEwma) : 0.2
        let frecency = st.frecencyStored > 0
            ? min(exp(Self.lambda * (st.frecencyStored - now)) / 6.0, 1) : 0
        return min(0.5 * ppm + 0.3 * reuse + 0.2 * frecency, 1)
    }

    /// Iqbal-Horvitz protection: the app had a ≥5-min frontmost dwell that
    /// ended within the last 20 min (or is mid-dwell now).
    public func recentlyWorkedIn(app: String, now: Double) -> Bool {
        if app == currentApp, now - currentDwellStart >= Self.longDwellSeconds {
            return true
        }
        guard let st = apps[app] else { return false }
        return st.lastLongDwellEnd > 0 && now - st.lastLongDwellEnd < Self.dwellProtectWindow
    }

    /// Disruption multiplier from frontmost dwell (1…2).
    public func dwellMultiplier(app: String, now: Double) -> Double {
        var dwellMin = 0.0
        if app == currentApp {
            dwellMin = (now - currentDwellStart) / 60
        } else if let st = apps[app], st.lastLongDwellEnd > 0,
                  now - st.lastLongDwellEnd < 3600 {
            dwellMin = Self.longDwellSeconds / 60
        }
        return 1 + min(max(dwellMin / 30, 0), 1)
    }

    public func appsRecentlyWorkedIn(now: Double) -> Set<String> {
        var out = Set<String>()
        if let cur = currentApp, now - currentDwellStart >= Self.longDwellSeconds {
            out.insert(cur)
        }
        for (name, st) in apps
        where st.lastLongDwellEnd > 0 && now - st.lastLongDwellEnd < Self.dwellProtectWindow {
            out.insert(name)
        }
        return out
    }
}

/// SmartLMK-style action scoring: memory recovered per unit of expected user
/// disruption, discounted by the action type's own measured re-fault
/// precision (Acclaim, USENIX ATC 2020).
public enum ActionRanker {
    /// Restart/resume latency cost per action type, seconds (v1 constants;
    /// measurable later the SmartLMK way).
    public static let deltaT: [String: Double] = [
        "sigstop_process": 2.0,
        "chrome_discard_tabs": 3.0,
        "docker_pause": 5.0,
    ]
    public static let severity: [String: Double] = [
        "sigstop_process": 0.15,
        "chrome_discard_tabs": 0.30,
        "docker_pause": 0.20,
    ]

    public static func score(action: String, recoveryMb: Double, pReturn: Double,
                             dwellMult: Double, refaultPrecision: Double) -> Double {
        let disruption = (deltaT[action] ?? 3) * pReturn * dwellMult * (severity[action] ?? 0.3)
        return recoveryMb * refaultPrecision / (disruption + 0.05)
    }
}
