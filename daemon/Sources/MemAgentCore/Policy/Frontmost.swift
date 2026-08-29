import Foundation

/// Name of the app the user is actively using. Uses lsappinfo(1) rather than
/// NSWorkspace so it works reliably from a launchd background process.
public enum Frontmost {
    public static func appName() -> String? {
        guard let asn = run("/usr/bin/lsappinfo", ["front"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            asn.hasPrefix("ASN:") else { return nil }
        guard let info = run("/usr/bin/lsappinfo", ["info", "-only", "name", asn]) else { return nil }
        // Output looks like: "name"="Google Chrome"
        guard let eq = info.range(of: "=") else { return nil }
        return info[eq.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
