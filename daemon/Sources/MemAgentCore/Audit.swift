import Foundation

/// Append-only JSONL audit trail: every proposal, verdict, execution, and
/// revert lands here. One line per event: {"ts": ..., "kind": ..., "data": {...}}.
public final class Audit {
    private let url: URL
    private let queue = DispatchQueue(label: "memagent.audit")

    public init(url: URL) {
        self.url = url
    }

    public func append(kind: String, data: [String: Any]) {
        let entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "kind": kind,
            "data": data,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        queue.sync {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    public func append<T: Encodable>(kind: String, encodable: T) {
        let data = (try? JSON.encoder.encode(encodable))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        append(kind: kind, data: data)
    }
}
