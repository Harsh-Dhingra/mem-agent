import Darwin
import Foundation

/// Everything the validator needs to judge a plan, captured as plain data so
/// the decision table is a pure function (and fully unit-testable).
public struct ValidationContext {
    public var frontmostAppName: String?
    public var idleSeconds: [Int32: Double]
    public var liveNames: [Int32: String]  // pid → current process name
    public var dockerAvailable: Bool
    public var suspendedPids: Set<Int32>
    public var chromeConnected: Bool
    public var chromeDiscardableTabs: Int

    public init(frontmostAppName: String?, idleSeconds: [Int32: Double],
                liveNames: [Int32: String], dockerAvailable: Bool,
                suspendedPids: Set<Int32> = [],
                chromeConnected: Bool = false, chromeDiscardableTabs: Int = 0) {
        self.frontmostAppName = frontmostAppName
        self.idleSeconds = idleSeconds
        self.liveNames = liveNames
        self.dockerAvailable = dockerAvailable
        self.suspendedPids = suspendedPids
        self.chromeConnected = chromeConnected
        self.chromeDiscardableTabs = chromeDiscardableTabs
    }
}

/// The deterministic safety core. LLM proposes, this disposes — every action
/// from any source passes through the same default-deny decision table.
public enum Validator {
    public static let knownActions: Set<String> = ["sigstop_process", "docker_pause",
                                                   "chrome_discard_tabs", "report"]

    public static func validate(_ actions: [ProposedAction],
                                policy: Policy,
                                context: ValidationContext) -> [ActionVerdict] {
        var allowedCount = 0
        return actions.map { action in
            let verdict = judge(action, policy: policy, context: context,
                                allowedSoFar: allowedCount)
            if verdict == "allowed", action.action != "report" {
                allowedCount += 1
            }
            return ActionVerdict(id: UUID().uuidString.lowercased(),
                                 action: action,
                                 allowed: verdict == "allowed",
                                 verdict: verdict)
        }
    }

    private static func judge(_ a: ProposedAction, policy: Policy,
                              context: ValidationContext, allowedSoFar: Int) -> String {
        guard knownActions.contains(a.action) else {
            return "denied: unknown action '\(a.action)'"
        }
        if a.action == "report" { return "allowed" }  // report is always safe

        if policy.autonomy == "off" {
            return "denied: autonomy is off"
        }
        if a.action == "chrome_discard_tabs" {
            // Tab discard is Chrome-native, non-destructive (tabs reload on
            // click), and pre-filtered to inactive/unpinned/silent tabs — the
            // process-level rules below don't apply.
            guard context.chromeConnected else {
                return "denied: mem-agent Chrome extension not connected"
            }
            guard context.chromeDiscardableTabs > 0 else {
                return "denied: no discardable tabs (inactive >5 min, not pinned/audible)"
            }
            guard allowedSoFar < policy.maxActionsPerEscalation else {
                return "denied: exceeds cap of \(policy.maxActionsPerEscalation) actions per escalation"
            }
            return "allowed"
        }
        if a.action == "docker_pause", !context.dockerAvailable {
            return "denied: docker CLI not available on this machine"
        }
        if context.suspendedPids.contains(a.targetPid) {
            return "denied: pid \(a.targetPid) is already suspended by mem-agent"
        }
        guard let liveName = context.liveNames[a.targetPid] else {
            return "denied: pid \(a.targetPid) not found"
        }
        guard liveName == a.targetName else {
            return "denied: pid \(a.targetPid) is now '\(liveName)', not '\(a.targetName)' (pid reuse?)"
        }
        if isProtected(name: liveName, policy: policy) {
            return "denied: '\(liveName)' is protected"
        }
        if policy.neverTouchFrontmost, let front = context.frontmostAppName,
           liveName == front {
            return "denied: '\(liveName)' is the frontmost app"
        }
        guard policy.manageable.contains(liveName) else {
            return "denied: '\(liveName)' is not in the manageable allowlist"
        }
        let idle = context.idleSeconds[a.targetPid] ?? 0
        guard idle >= Double(policy.minIdleSeconds) else {
            return "denied: idle \(Int(idle))s < required \(policy.minIdleSeconds)s"
        }
        guard allowedSoFar < policy.maxActionsPerEscalation else {
            return "denied: exceeds cap of \(policy.maxActionsPerEscalation) actions per escalation"
        }
        return "allowed"
    }

    public static func isProtected(name: String, policy: Policy) -> Bool {
        if policy.protected.contains(name) { return true }
        return policy.protectedPatterns.contains { pattern in
            fnmatch(pattern, name, 0) == 0
        }
    }
}
