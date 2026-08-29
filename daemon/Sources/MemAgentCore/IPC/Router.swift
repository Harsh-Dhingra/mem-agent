import Foundation

/// Newline-delimited JSON request router. Wire format:
///   request:  {"id": 1, "method": "state", "params": {...}}
///   response: {"id": 1, "result": {...}} | {"id": 1, "error": {"code": "...", "message": "..."}}
public final class Router {
    let engine: Engine

    public init(engine: Engine) {
        self.engine = engine
    }

    struct ErrorBody: Codable {
        var code: String
        var message: String
    }
    struct ErrorEnvelope: Codable {
        var id: Int?
        var error: ErrorBody
    }
    struct Envelope<T: Encodable>: Encodable {
        var id: Int?
        var result: T
    }

    public func handle(line: Data) -> Data {
        var id: Int?
        do {
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = obj["method"] as? String else {
                return errorData(id: nil, code: "bad_request", message: "expected {id, method, params}")
            }
            id = obj["id"] as? Int
            let params = obj["params"] as? [String: Any] ?? [:]
            return try dispatch(id: id, method: method, params: params)
        } catch {
            return errorData(id: id, code: "internal", message: "\(error)")
        }
    }

    private func dispatch(id: Int?, method: String, params: [String: Any]) throws -> Data {
        switch method {
        case "ping":
            struct Pong: Codable { var ok: Bool; var version: String }
            return try resultData(id: id, Pong(ok: true, version: memAgentVersion))

        case "state":
            let (snap, info) = try engine.queue.sync { try engine.currentState() }
            struct State: Codable { var system: SystemSnapshot; var daemon: DaemonInfo }
            return try resultData(id: id, State(system: snap, daemon: info))

        case "top":
            let n = params["n"] as? Int ?? 10
            let groups = engine.queue.sync { engine.topConsumers(n: n) }
            return try resultData(id: id, groups)

        case "predict":
            let p = engine.queue.sync { engine.prediction() }
            return try resultData(id: id, p)

        case "anomalies":
            let a = engine.queue.sync { engine.activeAnomalies() }
            return try resultData(id: id, a)

        case "history":
            guard let pid = params["pid"] as? Int else {
                return errorData(id: id, code: "bad_request", message: "history requires params.pid")
            }
            let minutes = params["minutes"] as? Double ?? 30
            let rows = try engine.queue.sync { try engine.history(pid: Int32(pid), minutes: minutes) }
            return try resultData(id: id, rows)

        case "chrome_sync":
            // From the native-messaging host: tab inventory in, discard ids out.
            guard let rawTabs = params["tabs"] as? [[String: Any]] else {
                return errorData(id: id, code: "bad_request", message: "chrome_sync requires params.tabs")
            }
            let data = try JSONSerialization.data(withJSONObject: rawTabs)
            let tabs = try JSON.decoder.decode([ChromeTab].self, from: data)
            let focusedWindow = params["focused_window_id"] as? Int
            let discards = engine.queue.sync {
                engine.chromeSync(tabs: tabs, focusedWindowId: focusedWindow)
            }
            struct SyncResult: Codable { var discardTabIds: [Int] }
            return try resultData(id: id, SyncResult(discardTabIds: discards))

        case "chrome_status":
            return try resultData(id: id, engine.queue.sync { engine.chromeStatus() })

        case "policy_get":
            return try resultData(id: id, try Policy.loadOrCreateDefault())

        case "audit_tail":
            let n = params["n"] as? Int ?? 50
            let lines = (try? String(contentsOf: Paths.auditLog, encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(n).map(String.init) } ?? []
            struct Tail: Codable { var lines: [String] }
            return try resultData(id: id, Tail(lines: lines))

        case "propose":
            // May block for the escalation timeout when use_llm is set; runs on
            // the connection thread, never on the engine queue.
            let useLLM = params["use_llm"] as? Bool ?? false
            let source = params["source"] as? String ?? "manual"
            return try resultData(id: id, engine.propose(useLLM: useLLM, source: source))

        case "execute":
            guard let actionID = params["action_id"] as? String else {
                return errorData(id: id, code: "bad_request", message: "execute requires params.action_id")
            }
            return try resultData(id: id, engine.execute(actionID: actionID))

        case "policy_set":
            do {
                let updated = try engine.setPolicy(
                    autonomy: params["autonomy"] as? String,
                    addManageable: params["add_manageable"] as? [String] ?? [],
                    removeManageable: params["remove_manageable"] as? [String] ?? [],
                    addProtected: params["add_protected"] as? [String] ?? [],
                    removeProtected: params["remove_protected"] as? [String] ?? [])
                return try resultData(id: id, updated)
            } catch {
                return errorData(id: id, code: "bad_request", message: error.localizedDescription)
            }

        default:
            return errorData(id: id, code: "unknown_method", message: "no such method: \(method)")
        }
    }

    private func resultData<T: Encodable>(id: Int?, _ value: T) throws -> Data {
        var data = try JSON.encoder.encode(Envelope(id: id, result: value))
        data.append(0x0A)
        return data
    }

    private func errorData(id: Int?, code: String, message: String) -> Data {
        let env = ErrorEnvelope(id: id, error: ErrorBody(code: code, message: message))
        var data = (try? JSON.encoder.encode(env)) ?? Data("{\"error\":{\"code\":\"internal\"}}".utf8)
        data.append(0x0A)
        return data
    }
}
