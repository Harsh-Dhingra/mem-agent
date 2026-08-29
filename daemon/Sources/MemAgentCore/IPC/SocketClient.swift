import Darwin
import Foundation

public enum SocketClientError: Error, CustomStringConvertible {
    case daemonUnavailable(String)
    case badResponse(String)
    case remote(code: String, message: String)

    public var description: String {
        switch self {
        case .daemonUnavailable(let path):
            return "daemon not reachable at \(path) — start it with `memagent run` or `memagent install`"
        case .badResponse(let m): return "bad response from daemon: \(m)"
        case .remote(let code, let message): return "daemon error [\(code)]: \(message)"
        }
    }
}

/// Client side of the daemon socket: one request per connection, shared by the
/// CLI, the menu-bar app, and tests.
public enum SocketClient {
    public static func call(method: String, params: [String: Any] = [:],
                            timeoutSeconds: Int = 3) throws -> Any {
        let path = Paths.socket.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.daemonUnavailable(path) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: Array(path.utf8))
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        guard ok == 0 else { throw SocketClientError.daemonUnavailable(path) }

        var request: [String: Any] = ["id": 1, "method": method]
        if !params.isEmpty { request["params"] = params }
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw SocketClientError.badResponse("connection closed early") }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw SocketClientError.badResponse(String(data: line, encoding: .utf8) ?? "<binary>")
        }
        if let err = obj["error"] as? [String: Any] {
            throw SocketClientError.remote(
                code: err["code"] as? String ?? "unknown",
                message: err["message"] as? String ?? "")
        }
        guard let result = obj["result"] else {
            throw SocketClientError.badResponse("missing result")
        }
        return result
    }

    public static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
