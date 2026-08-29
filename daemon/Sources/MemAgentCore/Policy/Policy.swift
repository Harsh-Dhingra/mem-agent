import Foundation

/// Deterministic action policy, stored at ~/.config/mem-agent/policy.json.
/// Decoding is default-tolerant: missing keys fall back to `Policy.default`
/// so old policy files keep working across upgrades.
public struct Policy: Codable {
    public struct Escalation: Codable {
        public var minIntervalSeconds: Int
        public var maxPerHour: Int
        public var claudePath: String?
        public var model: String
        public var timeoutSeconds: Int

        public init(minIntervalSeconds: Int, maxPerHour: Int, claudePath: String?,
                    model: String, timeoutSeconds: Int) {
            self.minIntervalSeconds = minIntervalSeconds
            self.maxPerHour = maxPerHour
            self.claudePath = claudePath
            self.model = model
            self.timeoutSeconds = timeoutSeconds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Policy.default.escalation
            minIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .minIntervalSeconds) ?? d.minIntervalSeconds
            maxPerHour = try c.decodeIfPresent(Int.self, forKey: .maxPerHour) ?? d.maxPerHour
            claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        }
    }

    public var version: Int
    public var autonomy: String            // "off" | "suggest" | "auto_reversible"
    public var protected: [String]
    public var protectedPatterns: [String]
    public var manageable: [String]
    public var neverTouchFrontmost: Bool
    public var minIdleSeconds: Int
    public var maxActionsPerEscalation: Int
    public var autoRevertSeconds: Int      // reversible actions revert after this, or when pressure clears
    public var escalation: Escalation

    public static let autonomyLevels: Set<String> = ["off", "suggest", "auto_reversible"]

    public init(version: Int, autonomy: String, protected: [String], protectedPatterns: [String],
                manageable: [String], neverTouchFrontmost: Bool, minIdleSeconds: Int,
                maxActionsPerEscalation: Int, autoRevertSeconds: Int, escalation: Escalation) {
        self.version = version
        self.autonomy = autonomy
        self.protected = protected
        self.protectedPatterns = protectedPatterns
        self.manageable = manageable
        self.neverTouchFrontmost = neverTouchFrontmost
        self.minIdleSeconds = minIdleSeconds
        self.maxActionsPerEscalation = maxActionsPerEscalation
        self.autoRevertSeconds = autoRevertSeconds
        self.escalation = escalation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Policy.default
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        autonomy = try c.decodeIfPresent(String.self, forKey: .autonomy) ?? d.autonomy
        protected = try c.decodeIfPresent([String].self, forKey: .protected) ?? d.protected
        protectedPatterns = try c.decodeIfPresent([String].self, forKey: .protectedPatterns) ?? d.protectedPatterns
        manageable = try c.decodeIfPresent([String].self, forKey: .manageable) ?? d.manageable
        neverTouchFrontmost = try c.decodeIfPresent(Bool.self, forKey: .neverTouchFrontmost) ?? d.neverTouchFrontmost
        minIdleSeconds = try c.decodeIfPresent(Int.self, forKey: .minIdleSeconds) ?? d.minIdleSeconds
        maxActionsPerEscalation = try c.decodeIfPresent(Int.self, forKey: .maxActionsPerEscalation) ?? d.maxActionsPerEscalation
        autoRevertSeconds = try c.decodeIfPresent(Int.self, forKey: .autoRevertSeconds) ?? d.autoRevertSeconds
        escalation = try c.decodeIfPresent(Escalation.self, forKey: .escalation) ?? d.escalation
    }

    public static var `default`: Policy {
        Policy(
            version: 1,
            autonomy: "suggest",
            protected: [
                "WindowServer", "loginwindow", "kernel_task", "launchd",
                "Terminal", "iTerm2", "claude", "memagent",
                "zoom.us", "FaceTime", "Meeting Center",
            ],
            protectedPatterns: ["*Helper (GPU)*"],
            manageable: [],
            neverTouchFrontmost: true,
            minIdleSeconds: 60,
            maxActionsPerEscalation: 3,
            autoRevertSeconds: 900,
            escalation: Escalation(
                minIntervalSeconds: 900,
                maxPerHour: 3,
                claudePath: nil,
                model: "claude-haiku-4-5",
                timeoutSeconds: 60))
    }

    public static func loadOrCreateDefault() throws -> Policy {
        let url = Paths.policy
        if let data = try? Data(contentsOf: url) {
            return try JSON.decoder.decode(Policy.self, from: data)
        }
        let policy = Policy.default
        try Paths.ensureDirectories()
        try policy.save()
        return policy
    }

    public func save() throws {
        try JSON.prettyEncoder.encode(self).write(to: Paths.policy)
    }

    public func prettyJSON() throws -> String {
        try JSON.encodeString(self, pretty: true)
    }
}
