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
            var params: [String: Any] = ["tabs": tabs]
            if let focused = obj["focused_window_id"] {
                params["focused_window_id"] = focused
            }
            let result = try SocketClient.call(method: "chrome_sync", params: params)
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

/// Registers the native-messaging host with every installed Chromium-family
/// browser and prints extension install steps.
enum ChromeInstallCommand {
    static let hostName = "com.memagent.chrome"
    /// Stable dev extension id derived from the `key` in the extension manifest.
    static let extensionID = "hmbdhbcmcnfbbeebfkogdekejkgpejfd"
    /// A Chrome Web Store install has a different, store-assigned id; once
    /// known it's saved here so re-installs keep honoring it.
    static var storeIDFile: URL {
        Paths.home.appendingPathComponent(".config/mem-agent/store-extension-id")
    }

    /// App Support subpaths of Chromium-family browsers (relative to
    /// ~/Library/Application Support). The host manifest is written into each
    /// browser that is actually present; Chrome always gets one.
    static let browserDirs: [(name: String, path: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
    ]

    static func install(extensionDir: String, storeExtensionID: String? = nil) throws {
        let fm = FileManager.default
        let wrapper = Paths.home.appendingPathComponent(".local/bin/memagent-chrome-host")
        let script = """
        #!/bin/zsh
        exec "\(Paths.installedBinary.path)" chrome-host
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        // Remember a store id across re-installs.
        if let storeExtensionID {
            try? storeExtensionID.write(to: storeIDFile, atomically: true, encoding: .utf8)
        }
        var origins = ["chrome-extension://\(extensionID)/"]
        if let saved = try? String(contentsOf: storeIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            origins.append("chrome-extension://\(saved)/")
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "mem-agent Chrome tab bridge",
            "path": wrapper.path,
            "type": "stdio",
            "allowed_origins": origins,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])

        let appSupport = Paths.home.appendingPathComponent("Library/Application Support")
        var registered: [String] = []
        for browser in browserDirs {
            let base = appSupport.appendingPathComponent(browser.path)
            // Only register into browsers that exist — except Chrome, always.
            guard browser.name == "Chrome" || fm.fileExists(atPath: base.path) else { continue }
            let dir = base.appendingPathComponent("NativeMessagingHosts")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(hostName).json"))
            registered.append(browser.name)
        }

        print("native messaging host registered for: \(registered.joined(separator: ", "))")
        if origins.count > 1 {
            print("allowed extension ids: dev + store (\(origins.count) origins)")
        }
        print("")
        print("Finish in your browser (one time):")
        print("  1. chrome://extensions → enable Developer mode")
        print("  2. Load unpacked → \(extensionDir)")
        print("  3. Check: memagent chrome-status (connected within ~30s)")
        print("")
        print("After the Web Store listing is live, rerun with the store id:")
        print("  memagent chrome-install --store-id <id-from-web-store>")
    }

    static func status() throws {
        let result = try SocketClient.call(method: "chrome_status")
        try SocketClient.printJSON(result)
    }
}
