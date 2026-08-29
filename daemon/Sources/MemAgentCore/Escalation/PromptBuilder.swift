import Foundation

/// Builds the escalation prompt: pre-digested state plus a pre-filtered legal
/// action menu. The model never sees raw system access — it picks from a menu,
/// and the Validator re-checks whatever comes back anyway.
public enum PromptBuilder {
    public struct MenuItem: Codable {
        public var action: String
        public var targetPid: Int32
        public var targetName: String
        public var footprintMb: Double
        public var idleSeconds: Double
    }

    /// Candidates the policy would plausibly allow right now.
    public static func legalMenu(processes: [ProcessSample],
                                 idle: [Int32: Double],
                                 frontmost: String?,
                                 policy: Policy,
                                 suspendedPids: Set<Int32> = []) -> [MenuItem] {
        processes
            .filter { p in
                !suspendedPids.contains(p.pid)
                    && policy.manageable.contains(p.name)
                    && !Validator.isProtected(name: p.name, policy: policy)
                    && p.name != frontmost
                    && (idle[p.pid] ?? 0) >= Double(policy.minIdleSeconds)
            }
            .sorted { $0.footprintBytes > $1.footprintBytes }
            .prefix(10)
            .map { p in
                MenuItem(action: "sigstop_process", targetPid: p.pid, targetName: p.name,
                         footprintMb: Double(p.footprintBytes) / 1_048_576,
                         idleSeconds: idle[p.pid] ?? 0)
            }
    }

    public static func build(system: SystemSnapshot,
                             top: [ConsumerGroup],
                             anomalies: [Anomaly],
                             prediction: Prediction,
                             menu: [MenuItem],
                             policy: Policy) -> String {
        let topLines = top.prefix(10).map {
            "- \($0.name): \(formatBytes($0.footprintBytes)) (\($0.processCount) procs)"
        }.joined(separator: "\n")
        let anomalyLines = anomalies.isEmpty ? "none" : anomalies.prefix(5).map {
            String(format: "- %@ (pid %d): %@ now, leaking %.0f MB/h vs learned ceiling %@%@",
                   $0.name, $0.pid, formatBytes($0.footprintBytes), $0.slopeMbPerHour,
                   formatBytes($0.ceilingBytes),
                   $0.tteHours.map { String(format: ", exhaustion in ~%.1f h", $0) } ?? "")
        }.joined(separator: "\n")
        let menuJSON = (try? JSON.encodeString(menu)) ?? "[]"
        let eta = prediction.etaMinutesToCritical.map { String(format: "%.0f min", $0) } ?? "none"

        return """
        You are the escalation reasoner for a macOS memory-management daemon. Memory pressure is \
        rising and you must pick the least disruptive recovery actions.

        SYSTEM
        used \(formatBytes(system.usedBytes)) / \(formatBytes(system.totalBytes)), pressure \(system.pressure.label), \
        estimated available \(formatBytes(system.availBytes)), swap used \(formatBytes(system.swapUsedBytes)).
        ETA to critical pressure: \(eta) (confidence \(prediction.confidence)).

        TOP CONSUMERS
        \(topLines)

        GROWTH ANOMALIES
        \(anomalyLines)

        LEGAL ACTION MENU — you may ONLY choose actions from this list (verbatim pid+name), plus \
        "report" items for anything else worth telling the user about:
        \(menuJSON)

        Pick at most \(policy.maxActionsPerEscalation) actions. Prefer the largest recovery with the \
        least disruption. If the menu is empty or nothing is worth doing, return an empty plan with a \
        report explaining what the user should do manually.

        Respond with ONLY this JSON, no prose, no code fences:
        {"analysis": "<one paragraph>", "confidence": "low|medium|high", "plan": [{"action": "sigstop_process|chrome_discard_tabs|report", "target_pid": <int>, "target_name": "<string>", "reason": "<string>", "expected_mb_freed": <number>}]}
        """
    }
}
