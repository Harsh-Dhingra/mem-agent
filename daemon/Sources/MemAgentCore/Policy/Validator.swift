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
    // v0.3 fields.
    public var pressureLevel: Int                     // 1 / 2 / 4 → lmkd-style bands
    public var recentlyWorkedInApps: Set<String>      // Iqbal-Horvitz dwell protection
    public var disabledActionTypes: Set<String>       // Acclaim re-fault auto-disable
    public var executedActionsLastHour: Int           // Falcon disruption budget
    public var lastActionTsByTarget: [String: Double] // per-target cooldown
    public var now: Double

    public init(frontmostAppName: String?, idleSeconds: [Int32: Double],
                liveNames: [Int32: String], dockerAvailable: Bool,
                suspendedPids: Set<Int32> = [],
                chromeConnected: Bool = false, chromeDiscardableTabs: Int = 0,
                pressureLevel: Int = 1,
                recentlyWorkedInApps: Set<String> = [],
                disabledActionTypes: Set<String> = [],
                executedActionsLastHour: Int = 0,
                lastActionTsByTarget: [String: Double] = [:],
                now: Double = Date().timeIntervalSince1970) {
        self.frontmostAppName = frontmostAppName
        self.idleSeconds = idleSeconds
        self.liveNames = liveNames
        self.dockerAvailable = dockerAvailable
        self.suspendedPids = suspendedPids
        self.chromeConnected = chromeConnected
        self.chromeDiscardableTabs = chromeDiscardableTabs
        self.pressureLevel = pressureLevel
        self.recentlyWorkedInApps = recentlyWorkedInApps
        self.disabledActionTypes = disabledActionTypes
        self.executedActionsLastHour = executedActionsLastHour
        self.lastActionTsByTarget = lastActionTsByTarget
        self.now = now
    }
}

/// The deterministic safety core. LLM proposes, this disposes — every action
/// from any source passes through the same default-deny decision table.
///
/// v0.3 adds four literature-backed rules:
///  - lmkd-style bands: process suspension needs idle > 30 min at WARN
///    pressure, > 5 min at CRITICAL (the pressure level determines how deep
///    into the stack you may reach);
///  - the Iqbal-Horvitz dwell rule (CHI 2007): an app the user worked in for
///    ≥5 min within the last 20 min is untouchable — pure idle-time ranking
///    gets that case exactly backwards;
///  - a Falcon-style disruption budget (≤4 executed actions/hour, ≥30 min per
///    target);
///  - Acclaim re-fault auto-disable: an action type that keeps getting undone
///    by the user is denied wholesale.
public enum Validator {
    public static let knownActions: Set<String> = ["sigstop_process", "docker_pause",
                                                   "chrome_discard_tabs", "report"]
    public static let maxActionsPerHour = 4
    public static let perTargetCooldown = 1800.0
    public static let warnBandIdleSeconds = 1800.0
    public static let criticalBandIdleSeconds = 300.0

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
        if context.disabledActionTypes.contains(a.action) {
            return "denied: '\(a.action)' auto-disabled (re-fault rate > 25% — users kept undoing it)"
        }
        if context.executedActionsLastHour >= Self.maxActionsPerHour {
            return "denied: hourly disruption budget exhausted (\(Self.maxActionsPerHour) actions)"
        }
        if let last = context.lastActionTsByTarget[a.targetName],
           context.now - last < Self.perTargetCooldown {
            return "denied: '\(a.targetName)' was acted on \(Int((context.now - last) / 60)) min ago (30-min per-target cooldown)"
        }

        if a.action == "chrome_discard_tabs" {
            // Tab discard is Chrome-native, non-destructive (tabs reload on
            // click), and pre-filtered to inactive/unpinned/silent tabs in
            // non-focused windows — the process-level rules below don't apply.
            guard context.chromeConnected else {
                return "denied: mem-agent Chrome extension not connected"
            }
            guard context.chromeDiscardableTabs > 0 else {
                return "denied: no discardable tabs (inactive >5 min, not pinned/audible/focused-window)"
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
        if context.recentlyWorkedInApps.contains(liveName) {
            return "denied: '\(liveName)' had a ≥5-min working session within the last 20 min (dwell rule)"
        }
        guard policy.manageable.contains(liveName) else {
            return "denied: '\(liveName)' is not in the manageable allowlist"
        }
        // lmkd band gate: pressure level bounds how deep we may reach.
        let bandIdle = context.pressureLevel >= 4
            ? Self.criticalBandIdleSeconds : Self.warnBandIdleSeconds
        let requiredIdle = max(Double(policy.minIdleSeconds), bandIdle)
        let idle = context.idleSeconds[a.targetPid] ?? 0
        guard idle >= requiredIdle else {
            return "denied: idle \(Int(idle))s < required \(Int(requiredIdle))s for pressure band \(context.pressureLevel)"
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
