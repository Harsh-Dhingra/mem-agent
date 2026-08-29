import Darwin
import Foundation

/// Executes validated actions and guarantees their reversal: every SIGSTOP
/// gets an auto-SIGCONT deadline, everything reverts on daemon shutdown, and
/// nothing here runs unless a Validator verdict said "allowed".
public final class Executor {
    public struct Suspension {
        public var pid: Int32
        public var name: String
        public var kind: String       // "sigstop" | "docker_pause"
        public var startedAt: Double
        public var revertAt: Double
    }

    private(set) public var suspensions: [Int32: Suspension] = [:]

    public init() {}

    public func execute(_ verdict: ActionVerdict, policy: Policy, audit: Audit) -> ExecutionResult {
        guard verdict.allowed else {
            return ExecutionResult(id: verdict.id, executed: false,
                                   detail: "refused: verdict is '\(verdict.verdict)'",
                                   autoRevertAt: nil)
        }
        let a = verdict.action
        let now = Date().timeIntervalSince1970
        let revertAt = now + Double(policy.autoRevertSeconds)

        let result: ExecutionResult
        switch a.action {
        case "report":
            result = ExecutionResult(id: verdict.id, executed: true,
                                     detail: "report noted (no system change)", autoRevertAt: nil)

        case "sigstop_process":
            // kill(pid, 0) is the same-uid/permission probe.
            guard kill(a.targetPid, 0) == 0 else {
                result = ExecutionResult(id: verdict.id, executed: false,
                                         detail: "cannot signal pid \(a.targetPid) (errno \(errno))",
                                         autoRevertAt: nil)
                break
            }
            guard kill(a.targetPid, SIGSTOP) == 0 else {
                result = ExecutionResult(id: verdict.id, executed: false,
                                         detail: "SIGSTOP failed (errno \(errno))", autoRevertAt: nil)
                break
            }
            suspensions[a.targetPid] = Suspension(
                pid: a.targetPid, name: a.targetName, kind: "sigstop",
                startedAt: now, revertAt: revertAt)
            result = ExecutionResult(id: verdict.id, executed: true,
                                     detail: "SIGSTOP sent to \(a.targetName) (pid \(a.targetPid)); auto-SIGCONT in \(policy.autoRevertSeconds)s or when pressure clears",
                                     autoRevertAt: revertAt)

        case "docker_pause":
            let (code, out) = Executor.shell("docker", "pause", a.targetName)
            if code == 0 {
                suspensions[a.targetPid] = Suspension(
                    pid: a.targetPid, name: a.targetName, kind: "docker_pause",
                    startedAt: now, revertAt: revertAt)
                result = ExecutionResult(id: verdict.id, executed: true,
                                         detail: "docker pause \(a.targetName)", autoRevertAt: revertAt)
            } else {
                result = ExecutionResult(id: verdict.id, executed: false,
                                         detail: "docker pause failed: \(out.prefix(200))", autoRevertAt: nil)
            }

        default:
            result = ExecutionResult(id: verdict.id, executed: false,
                                     detail: "unknown action", autoRevertAt: nil)
        }

        audit.append(kind: "execute", data: [
            "id": verdict.id, "action": a.action, "target_pid": Int(a.targetPid),
            "target_name": a.targetName, "executed": result.executed, "detail": result.detail,
        ])
        return result
    }

    /// Revert suspensions whose deadline passed — or all of them the moment
    /// kernel pressure is back to normal (the suspension did its job).
    public func revertDue(pressureNormal: Bool, audit: Audit,
                          now: Double = Date().timeIntervalSince1970) {
        for (pid, s) in suspensions where pressureNormal || now >= s.revertAt {
            revert(s, reason: pressureNormal ? "pressure back to normal" : "deadline reached",
                   audit: audit)
            suspensions.removeValue(forKey: pid)
        }
    }

    /// Targeted early revert (e.g. the user came back to a suspended app).
    public func revertNow(pid: Int32, reason: String, audit: Audit) {
        guard let s = suspensions[pid] else { return }
        revert(s, reason: reason, audit: audit)
        suspensions.removeValue(forKey: pid)
    }

    /// Safety net on shutdown: never leave anything stopped behind us.
    public func revertAll(audit: Audit) {
        for (_, s) in suspensions {
            revert(s, reason: "daemon shutting down", audit: audit)
        }
        suspensions.removeAll()
    }

    private func revert(_ s: Suspension, reason: String, audit: Audit) {
        let ok: Bool
        switch s.kind {
        case "sigstop":
            ok = kill(s.pid, SIGCONT) == 0
        case "docker_pause":
            ok = Executor.shell("docker", "unpause", s.name).0 == 0
        default:
            ok = false
        }
        audit.append(kind: "revert", data: [
            "target_pid": Int(s.pid), "target_name": s.name, "kind": s.kind,
            "reason": reason, "ok": ok,
        ])
    }

    static func shell(_ args: String...) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public static func dockerAvailable() -> Bool {
        shell("which", "docker").0 == 0
    }
}
