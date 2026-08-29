import Foundation

/// One action proposed by the LLM (or the deterministic fallback). Wire shape
/// matches schema/escalation-plan.schema.json (snake_case via JSON coders).
public struct ProposedAction: Codable {
    public var action: String        // "sigstop_process" | "docker_pause" | "report"
    public var targetPid: Int32
    public var targetName: String
    public var reason: String
    public var expectedMbFreed: Double?

    public init(action: String, targetPid: Int32, targetName: String,
                reason: String, expectedMbFreed: Double? = nil) {
        self.action = action
        self.targetPid = targetPid
        self.targetName = targetName
        self.reason = reason
        self.expectedMbFreed = expectedMbFreed
    }
}

/// The strict shape headless `claude -p` must return.
public struct EscalationPlan: Codable {
    public var analysis: String
    public var confidence: String
    public var plan: [ProposedAction]

    /// Tolerant extraction: accepts raw JSON or JSON wrapped in code fences /
    /// prose, by slicing from the first `{` to the last `}`.
    public static func parse(fromModelOutput text: String) -> EscalationPlan? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let slice = String(text[start...end])
        return try? JSON.decoder.decode(EscalationPlan.self, from: Data(slice.utf8))
    }
}

/// A validated action, addressable for execution by id.
public struct ActionVerdict: Codable {
    public var id: String
    public var action: ProposedAction
    public var allowed: Bool
    public var verdict: String       // "allowed" or the deny reason
}

public struct ExecutionResult: Codable {
    public var id: String
    public var executed: Bool
    public var detail: String
    public var autoRevertAt: Double? // epoch seconds, for reversible actions
}

public struct ProposalResult: Codable {
    public var source: String        // "llm" | "deterministic"
    public var analysis: String?
    public var confidence: String?
    public var verdicts: [ActionVerdict]
    public var escalationHealth: String  // "available" | reason unavailable
    public var estimatedRecoveryMb: Double
}
