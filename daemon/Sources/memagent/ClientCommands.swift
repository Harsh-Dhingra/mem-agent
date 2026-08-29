import Foundation
import MemAgentCore

/// CLI reads served by the running daemon over the unix socket — the same
/// interface the MCP plugin uses.
enum ClientCommands {
    static func top(n: Int, json: Bool) throws {
        do {
            let result = try SocketClient.call(method: "top", params: ["n": n])
            if json { try SocketClient.printJSON(result); return }
            guard let groups = result as? [[String: Any]] else { return }
            print("TOP CONSUMERS (grouped by app, via daemon)")
            for g in groups {
                let name = g["name"] as? String ?? "?"
                let count = g["process_count"] as? Int ?? 1
                let bytes = (g["footprint_bytes"] as? NSNumber)?.uint64Value ?? 0
                let procs = count == 1 ? "" : " (\(count) procs)"
                print("  \(formatBytes(bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)\(procs)")
            }
        } catch is SocketClientError {
            // Daemon down — fall back to a local sweep so `top` always works.
            let sweep = ProcessStats.sweep()
            let groups = Array(ProcessStats.group(sweep.samples).prefix(n))
            if json {
                print(try JSON.encodeString(groups, pretty: true))
            } else {
                print("TOP CONSUMERS (grouped by app, local sweep — daemon not running)")
                for g in groups {
                    let procs = g.processCount == 1 ? "" : " (\(g.processCount) procs)"
                    print("  \(formatBytes(g.footprintBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(g.name)\(procs)")
                }
            }
        }
    }

    static func predict(json: Bool) throws {
        let result = try SocketClient.call(method: "predict")
        if json { try SocketClient.printJSON(result); return }
        guard let p = result as? [String: Any] else { return }
        let avail = (p["avail_bytes"] as? NSNumber)?.uint64Value ?? 0
        let slope = (p["slope_bytes_per_sec"] as? NSNumber)?.doubleValue ?? 0
        let confidence = p["confidence"] as? String ?? "low"
        print("avail: \(formatBytes(avail))   trend: \(String(format: "%+.1f MB/min", slope * 60 / 1_048_576))   confidence: \(confidence)")
        if let eta = (p["eta_minutes_to_warn"] as? NSNumber)?.doubleValue {
            print(String(format: "ETA to warn pressure:     ~%.0f min", eta))
        }
        if let eta = (p["eta_minutes_to_critical"] as? NSNumber)?.doubleValue {
            print(String(format: "ETA to critical pressure: ~%.0f min", eta))
        } else if confidence == "low" || slope >= 0 {
            print("No critical pressure expected on the current trend.")
        }
        if let drivers = p["drivers"] as? [String], !drivers.isEmpty {
            print("drivers:")
            for d in drivers { print("  • \(d)") }
        }
    }

    static func anomalies(json: Bool) throws {
        let result = try SocketClient.call(method: "anomalies")
        if json { try SocketClient.printJSON(result); return }
        guard let list = result as? [[String: Any]], !list.isEmpty else {
            print("No active growth anomalies.")
            return
        }
        for a in list {
            let name = a["name"] as? String ?? "?"
            let pid = a["pid"] as? Int ?? 0
            let growth = (a["growth_bytes"] as? NSNumber)?.doubleValue ?? 0
            let fp = (a["footprint_bytes"] as? NSNumber)?.uint64Value ?? 0
            print("  \(name) (pid \(pid)): \(formatBytes(fp)) now, +\(formatBytes(growth)) above 30-min baseline")
        }
    }

    static func propose(useLLM: Bool, source: String, json: Bool) throws {
        // LLM proposals can take up to the escalation timeout; the default
        // 3s socket timeout would give up first.
        let result = try SocketClient.call(method: "propose",
                                           params: ["use_llm": useLLM, "source": source],
                                           timeoutSeconds: 90)
        if json { try SocketClient.printJSON(result); return }
        guard let p = result as? [String: Any] else { return }
        print("source: \(p["source"] as? String ?? "?")   escalation LLM: \(p["escalation_health"] as? String ?? "?")")
        if let analysis = p["analysis"] as? String {
            print("analysis: \(analysis)")
        }
        let recovery = (p["estimated_recovery_mb"] as? NSNumber)?.doubleValue ?? 0
        print(String(format: "estimated recovery from allowed actions: %.0f MB", recovery))
        guard let verdicts = p["verdicts"] as? [[String: Any]], !verdicts.isEmpty else {
            print("no actions proposed")
            return
        }
        for v in verdicts {
            let a = v["action"] as? [String: Any] ?? [:]
            let mark = (v["allowed"] as? Bool ?? false) ? "✓" : "✗"
            let id = (v["id"] as? String ?? "").prefix(8)
            print("  \(mark) [\(id)] \(a["action"] as? String ?? "?") \(a["target_name"] as? String ?? "") (pid \(a["target_pid"] as? Int ?? 0)) — \(v["verdict"] as? String ?? "")")
            if let reason = a["reason"] as? String {
                print("        \(reason)")
            }
        }
        print("execute with: memagent execute <full-action-id>  (see --json for full ids)")
    }

    static func execute(actionID: String) throws {
        let result = try SocketClient.call(method: "execute", params: ["action_id": actionID])
        try SocketClient.printJSON(result)
    }

    static func history(pid: Int32, json: Bool) throws {
        let result = try SocketClient.call(method: "history", params: ["pid": Int(pid), "minutes": 60])
        if json { try SocketClient.printJSON(result); return }
        guard let rows = result as? [[String: Any]], !rows.isEmpty else {
            print("No history for pid \(pid) (daemon samples the top \(Engine.processTopN) consumers every \(Int(Engine.processInterval))s).")
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        for r in rows {
            let ts = (r["ts"] as? NSNumber)?.doubleValue ?? 0
            let fp = (r["footprint_bytes"] as? NSNumber)?.uint64Value ?? 0
            print("  \(fmt.string(from: Date(timeIntervalSince1970: ts)))  \(formatBytes(fp))")
        }
    }
}
