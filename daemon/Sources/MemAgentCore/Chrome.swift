import Foundation

/// One Chrome tab as reported by the mem-agent extension over native messaging.
public struct ChromeTab: Codable {
    public var id: Int
    public var active: Bool
    public var audible: Bool
    public var pinned: Bool
    public var discarded: Bool
    public var lastAccessed: Double   // ms since epoch (chrome.tabs semantics)
    public var urlHost: String?
    public var title: String?

    public init(id: Int, active: Bool, audible: Bool, pinned: Bool, discarded: Bool,
                lastAccessed: Double, urlHost: String?, title: String?) {
        self.id = id
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
}

/// Daemon-side state for the Chrome tab bridge. The extension syncs every
/// ~30s; a discard command is queued here and picked up on the next sync.
/// Lives on the Engine queue (not thread-safe on its own).
public final class ChromeBridge {
    /// Extension alarm cadence is 30s; allow two missed beats.
    public static let staleAfterSeconds = 90.0
    /// A tab must be untouched this long before it is discardable.
    public static let minInactiveSeconds = 300.0
    /// Rough per-tab renderer footprint used for recovery estimates.
    public static let estimatedMbPerTab = 100.0

    private(set) public var tabs: [ChromeTab] = []
    private(set) public var lastSync: Double?
    private var pendingDiscards: Set<Int> = []

    public init() {}

    /// Handle one sync from the extension: store inventory, hand back (and
    /// clear) whatever discards were queued since the last sync.
    public func sync(tabs: [ChromeTab], at now: Double = Date().timeIntervalSince1970) -> [Int] {
        self.tabs = tabs
        lastSync = now
        // Only discard ids that still correspond to live, still-discardable tabs.
        let valid = Set(discardable(at: now).map(\.id))
        let out = pendingDiscards.intersection(valid)
        pendingDiscards.removeAll()
        return out.sorted()
    }

    public func connected(at now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let lastSync else { return false }
        return now - lastSync < Self.staleAfterSeconds
    }

    public func discardable(at now: Double = Date().timeIntervalSince1970) -> [ChromeTab] {
        tabs.filter { t in
            !t.active && !t.audible && !t.pinned && !t.discarded
                && now - t.lastAccessed / 1000 > Self.minInactiveSeconds
        }
    }

    /// Queue every currently discardable tab; returns how many were queued.
    public func enqueueDiscardAll(at now: Double = Date().timeIntervalSince1970) -> Int {
        let ids = discardable(at: now).map(\.id)
        pendingDiscards.formUnion(ids)
        return ids.count
    }

    public func status(at now: Double = Date().timeIntervalSince1970) -> ChromeStatus {
        ChromeStatus(connected: connected(at: now),
                     tabCount: tabs.count,
                     discardableCount: discardable(at: now).count,
                     lastSyncTs: lastSync,
                     pendingDiscards: pendingDiscards.count)
    }
}
