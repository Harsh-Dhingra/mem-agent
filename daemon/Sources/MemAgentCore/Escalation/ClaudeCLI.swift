import Foundation

/// Headless `claude -p` invoker. The CLI is not on launchd's PATH (and on some
/// machines not on any non-interactive PATH), so the path is resolved once via
/// a login shell, with a policy override taking precedence.
public final class ClaudeCLI {
    public enum Health {
        case available(path: String)
        case unavailable(String)

        public var label: String {
            switch self {
            case .available: return "available"
            case .unavailable(let why): return "unavailable: \(why)"
            }
        }
    }

    private var cached: Health?

    public init() {}

    public func health(policy: Policy) -> Health {
        if let cached { return cached }
        let resolved: Health
        if let override = policy.escalation.claudePath {
            resolved = FileManager.default.isExecutableFile(atPath: override)
                ? .available(path: override)
                : .unavailable("escalation.claude_path '\(override)' is not executable")
        } else {
            let (code, out) = Executor.shell("zsh", "-lc", "command -v claude")
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            resolved = (code == 0 && !path.isEmpty)
                ? .available(path: path)
                : .unavailable("claude CLI not found on PATH; set escalation.claude_path in \(Paths.policy.path)")
        }
        cached = resolved
        return resolved
    }

    /// Invalidate the cached resolution (e.g. after policy_set changes the path).
    public func reset() {
        cached = nil
    }

    public enum InvokeError: Error, CustomStringConvertible {
        case unavailable(String)
        case timeout(Int)
        case badOutput(String)

        public var description: String {
            switch self {
            case .unavailable(let why): return why
            case .timeout(let secs): return "claude -p timed out after \(secs)s"
            case .badOutput(let why): return "unparseable claude output: \(why)"
            }
        }
    }

    public func propose(prompt: String, policy: Policy) -> Result<EscalationPlan, InvokeError> {
        guard case .available(let path) = health(policy: policy) else {
            if case .unavailable(let why) = health(policy: policy) {
                return .failure(.unavailable(why))
            }
            return .failure(.unavailable("unresolved"))
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-p", prompt,
                          "--output-format", "json",
                          "--max-turns", "1",
                          "--model", policy.escalation.model]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            return .failure(.unavailable("failed to launch \(path): \(error)"))
        }

        let deadline = DispatchTime.now() + .seconds(policy.escalation.timeoutSeconds)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            task.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            task.terminate()
            return .failure(.timeout(policy.escalation.timeoutSeconds))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = envelope["result"] as? String else {
            return .failure(.badOutput("missing .result in CLI JSON envelope"))
        }
        guard let plan = EscalationPlan.parse(fromModelOutput: text) else {
            return .failure(.badOutput("result text did not contain a valid plan JSON"))
        }
        return .success(plan)
    }
}
