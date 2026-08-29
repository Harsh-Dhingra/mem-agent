import Foundation

public let memAgentVersion = "0.2.0"

// MARK: - Paths

public enum Paths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
    public static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/mem-agent", isDirectory: true)
    }
    public static var database: URL { appSupport.appendingPathComponent("mem-agent.sqlite") }
    public static var socket: URL { appSupport.appendingPathComponent("memagent.sock") }
    public static var auditLog: URL { appSupport.appendingPathComponent("audit.log") }
    public static var logsDir: URL {
        home.appendingPathComponent("Library/Logs/mem-agent", isDirectory: true)
    }
    public static var policy: URL {
        home.appendingPathComponent(".config/mem-agent/policy.json")
    }
    public static var launchAgentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.memagent.daemon.plist")
    }
    public static var installedBinary: URL {
        home.appendingPathComponent(".local/bin/memagent")
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, logsDir, policy.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - JSON helpers

public enum JSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
    public static var prettyEncoder: JSONEncoder {
        let e = encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    public static func encodeString<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try (pretty ? prettyEncoder : encoder).encode(value)
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - System snapshot

public enum PressureLevel: Int, Codable {
    case normal = 1, warn = 2, critical = 4
    public var label: String {
        switch self {
        case .normal: return "normal"
        case .warn: return "warn"
        case .critical: return "critical"
        }
    }
}

public struct SystemSnapshot: Codable {
    public var ts: Double            // epoch seconds
    public var totalBytes: UInt64
    public var freeBytes: UInt64     // free minus speculative
    public var activeBytes: UInt64
    public var inactiveBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var purgeableBytes: UInt64
    public var externalBytes: UInt64 // file-backed
    public var internalBytes: UInt64 // anonymous
    public var swapTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapIns: UInt64       // cumulative pages
    public var swapOuts: UInt64
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var pressureLevel: Int    // raw sysctl value (1/2/4)
    public var availBytes: UInt64    // free + purgeable + inactive * reclaimFactor

    public var pressure: PressureLevel { PressureLevel(rawValue: pressureLevel) ?? .normal }
    public var usedBytes: UInt64 {
        internalBytes &+ wiredBytes &+ compressedBytes
    }
}

// MARK: - Process sample

public struct ProcessSample: Codable {
    public var ts: Double
    public var pid: Int32
    public var name: String
    public var footprintBytes: UInt64
    public var residentBytes: UInt64
    public var cpuTime: UInt64  // mach units; deltas only
    public var source: String   // "rusage" | "ps"

    public init(ts: Double, pid: Int32, name: String, footprintBytes: UInt64,
                residentBytes: UInt64, cpuTime: UInt64, source: String) {
        self.ts = ts
        self.pid = pid
        self.name = name
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.cpuTime = cpuTime
        self.source = source
    }
}

public struct ConsumerGroup: Codable {
    public var name: String
    public var processCount: Int
    public var footprintBytes: UInt64
    public var pids: [Int32]
}

// MARK: - Prediction / anomalies

public struct Prediction: Codable {
    public var etaMinutesToWarn: Double?
    public var etaMinutesToCritical: Double?
    public var confidence: String        // "low" | "medium" | "high"
    public var slopeBytesPerSec: Double  // of avail; negative = shrinking
    public var availBytes: UInt64
    public var swapInRatePagesPerSec: Double
    public var drivers: [String]
}

public struct Anomaly: Codable {
    public var pid: Int32
    public var name: String
    public var footprintBytes: UInt64
    public var shortEwmaBytes: Double
    public var longEwmaBytes: Double
    public var growthBytes: Double
    public var firstDetectedTs: Double
}

// MARK: - Formatting

public func formatBytes(_ bytes: UInt64) -> String {
    formatBytes(Double(bytes))
}

public func formatBytes(_ bytes: Double) -> String {
    let gb = bytes / 1_073_741_824
    if gb >= 10 { return String(format: "%.1f GB", gb) }
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    let mb = bytes / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", bytes / 1024)
}
