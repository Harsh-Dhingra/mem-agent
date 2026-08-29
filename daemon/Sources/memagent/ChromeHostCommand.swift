import Darwin
import Foundation
import MemAgentCore

/// Chrome native-messaging host: speaks Chrome's framing (4-byte little-endian
/// length + JSON) on stdio and bridges each message to the daemon's
/// `chrome_sync` socket method. Chrome spawns this per sendNativeMessage call.
enum ChromeHostCommand {
    static func run() {
        while let message = readFramed() {
            let response = handle(message)
            writeFramed(response)
        }
    }

    static func handle(_ message: Data) -> Data {
        let fallback = Data("{\"discard_tab_ids\":[],\"error\":\"daemon unavailable\"}".utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let tabs = obj["tabs"] else {
            return Data("{\"discard_tab_ids\":[],\"error\":\"bad message\"}".utf8)
        }
        do {
            let result = try SocketClient.call(method: "chrome_sync", params: ["tabs": tabs])
            let data = try JSONSerialization.data(withJSONObject: result)
            return data
        } catch {
            return fallback
        }
    }

    static func readFramed() -> Data? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard readFully(into: &lenBuf) else { return nil }
        let length = Int(lenBuf[0]) | Int(lenBuf[1]) << 8 | Int(lenBuf[2]) << 16 | Int(lenBuf[3]) << 24
        guard length > 0, length < 8 * 1_048_576 else { return nil }
        var body = [UInt8](repeating: 0, count: length)
        guard readFully(into: &body) else { return nil }
        return Data(body)
    }

    static func readFully(into buffer: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(0, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    static func writeFramed(_ data: Data) {
        var frame = Data()
        let len = UInt32(data.count)
        frame.append(contentsOf: [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
                                  UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)])
        frame.append(data)
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(1, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}

/// Registers the native-messaging host with Chrome and prints extension
/// install steps.
enum ChromeInstallCommand {
    static let hostName = "com.memagent.chrome"
    /// Stable extension id derived from the `key` in the extension manifest.
    static let extensionID = "hmbdhbcmcnfbbeebfkogdekejkgpejfd"

    static func install(extensionDir: String) throws {
        let wrapper = Paths.home.appendingPathComponent(".local/bin/memagent-chrome-host")
        let script = """
        #!/bin/zsh
        exec "\(Paths.installedBinary.path)" chrome-host
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "mem-agent Chrome tab bridge",
            "path": wrapper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let dir = Paths.home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("\(hostName).json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: manifestURL)

        print("native messaging host registered: \(manifestURL.path)")
        print("")
        print("Finish in Chrome (one time):")
        print("  1. chrome://extensions → enable Developer mode")
        print("  2. Load unpacked → \(extensionDir)")
        print("  3. Check: memagent chrome-status (connected within ~30s)")
    }

    static func status() throws {
        let result = try SocketClient.call(method: "chrome_status")
        try SocketClient.printJSON(result)
    }
}
