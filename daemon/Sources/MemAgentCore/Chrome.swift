import Foundation

/// One Chrome tab as reported by the mem-agent extension over native messaging.
public struct ChromeTab: Codable {
    public var id: Int
    public var windowId: Int?
    public var active: Bool
    public var audible: Bool
    public var pinned: Bool
    public var discarded: Bool
    public var lastAccessed: Double   // ms since epoch (chrome.tabs semantics)
    public var urlHost: String?
    public var title: String?

    public init(id: Int, windowId: Int? = nil, active: Bool, audible: Bool, pinned: Bool,
                discarded: Bool, lastAccessed: Double, urlHost: String?, title: String?) {
        self.id = id
        self.windowId = windowId
        self.active = active
        self.audible = audible
        self.pinned = pinned
        self.discarded = discarded
        self.lastAccessed = lastAccessed
        self.urlHost = urlHost
        self.title = title
    }
}

public struct ChromeStatus: Codable {
    public var connected: Bool
    public var tabCount: Int
    public var discardableCount: Int
    public var lastSyncTs: Double?
    public var pendingDiscards: Int
    public var reactivations: Int      // discarded tabs the user came back to
}

/// Daemon-side state for the Chrome tab bridge (v0.3).
///
/// Design follows Chromium's own two-stage discard policy (TabRanker /
/// ChromiumOS tab-discard doc) and the CHI 2021 tab study ("When the Tab
/// Comes Due"): hard VETOES first (active, pinned, audible, recently used,
/// focused window — the user's visual working set), then a cheap ranker, and
/// only the bottom-K tabs are discarded — never the whole eligible set, and
/// the tab strip is never altered (discard ≠ close; the reminder survives).
/// Hosts the user reactivates after a discard earn protection (the Acclaim
/// re-fault principle applied per-host).
public final class ChromeBridge {
    public static let staleAfterSeconds = 90.0
    public static let minInactiveSeconds = 300.0
    public static let estimatedMbPerTab = 100.0
    static let reactivationWindow = 600.0

    private(set) public var tabs: [ChromeTab] = []
    private(set) public var lastSync: Double?
    private(set) public var focusedWindowId: Int?
    private var pendingDiscards: Set<Int> = []
    private var recentDiscards: [Int: (ts: Double, host: String?)] = [:]
    private(set) var hostReactivations: [String: Int] = [:]
    private(set) public var totalReactivations = 0

    public init() {}

    /// Handle one sync. Returns tab ids to discard now, plus how many
    /// previously discarded tabs the user reactivated (re-faults).
    public func sync(tabs: [ChromeTab], focusedWindowId: Int?,
                     at now: Double = Date().timeIntervalSince1970) -> (discard: [Int], refaults: Int) {
        // Re-fault detection: a tab we discarded is undiscarded again soon after.
        var refaults = 0
        for tab in tabs {
            if let record = recentDiscards[tab.id], !tab.discarded,
               now - record.ts < Self.reactivationWindow, now - record.ts > 5 {
                refaults += 1
                totalReactivations += 1
                if let host = record.host {
                    hostReactivations[host, default: 0] += 1
                }
                recentDiscards.removeValue(forKey: tab.id)
            }
        }
        recentDiscards = recentDiscards.filter { now - $0.value.ts < Self.reactivationWindow }

        self.tabs = tabs
        self.focusedWindowId = focusedWindowId
        lastSync = now

        let valid = Set(discardable(at: now).map(\.id))
        let out = pendingDiscards.intersection(valid)
        pendingDiscards.removeAll()
        for id in out {
            let host = tabs.first { $0.id == id }?.urlHost
            recentDiscards[id] = (now, host)
        }
        return (out.sorted(), refaults)
    }

    public func connected(at now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let lastSync else { return false }
        return now - lastSync < Self.staleAfterSeconds
    }

    /// Veto filter: never active, audible, pinned, already discarded,
    /// recently used, or in the focused window.
    public func discardable(at now: Double = Date().timeIntervalSince1970) -> [ChromeTab] {
        tabs.filter { t in
            !t.active && !t.audible && !t.pinned && !t.discarded
                && now - t.lastAccessed / 1000 > Self.minInactiveSeconds
                && (focusedWindowId == nil || t.windowId != focusedWindowId)
        }
    }

    /// Rank discardable tabs least-valuable-first: staleness dominates, but
    /// hosts the user has reactivated after past discards earn protection.
    func ranked(at now: Double) -> [ChromeTab] {
        discardable(at: now).sorted { a, b in
            discardPriority(a, now: now) > discardPriority(b, now: now)
        }
    }

    public func discardPriority(_ t: ChromeTab, now: Double) -> Double {
        let staleMinutes = (now - t.lastAccessed / 1000) / 60
        let protection = Double(t.urlHost.flatMap { hostReactivations[$0] } ?? 0)
        return staleMinutes - 30 * log(1 + protection)
    }

    /// Queue up to `maxTabs` of the least-valuable discardable tabs.
    /// Returns how many were queued.
    public func enqueueDiscards(maxTabs: Int,
                                at now: Double = Date().timeIntervalSince1970) -> Int {
        let victims = ranked(at: now).prefix(max(0, maxTabs))
        pendingDiscards.formUnion(victims.map(\.id))
        return victims.count
    }

    public func status(at now: Double = Date().timeIntervalSince1970) -> ChromeStatus {
        ChromeStatus(connected: connected(at: now),
                     tabCount: tabs.count,
                     discardableCount: discardable(at: now).count,
                     lastSyncTs: lastSync,
                     pendingDiscards: pendingDiscards.count,
                     reactivations: totalReactivations)
    }
}
