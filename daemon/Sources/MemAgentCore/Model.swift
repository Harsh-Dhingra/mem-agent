import Foundation

public let memAgentVersion = "0.3.0"

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

    public init(ts: Double, totalBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64,
                inactiveBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                purgeableBytes: UInt64, externalBytes: UInt64, internalBytes: UInt64,
                swapTotalBytes: UInt64, swapUsedBytes: UInt64, swapIns: UInt64,
                swapOuts: UInt64, pageIns: UInt64, pageOuts: UInt64, compressions: UInt64,
                pressureLevel: Int, availBytes: UInt64) {
        self.ts = ts
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.purgeableBytes = purgeableBytes
        self.externalBytes = externalBytes
        self.internalBytes = internalBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.compressions = compressions
        self.pressureLevel = pressureLevel
        self.availBytes = availBytes
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
    public var etaMinutesToCritical: Double? // median of the first-passage distribution
    public var etaP10Minutes: Double?        // pessimistic (10th percentile) ETA
    public var pPressure15min: Double        // P(avail crosses learned critical θ within 15 min)
    public var confidence: String            // "low" | "medium" | "high"
    public var slopeBytesPerSec: Double      // of avail; negative = shrinking
    public var availBytes: UInt64
    public var swapInRatePagesPerSec: Double
    public var regimeShiftRecent: Bool       // Page-Hinkley fired in the last 2 min
    public var thetaCriticalBytes: UInt64    // the learned critical threshold in force
    public var drivers: [String]

    public init(etaMinutesToWarn: Double? = nil, etaMinutesToCritical: Double? = nil,
                etaP10Minutes: Double? = nil, pPressure15min: Double = 0,
                confidence: String = "low", slopeBytesPerSec: Double = 0,
                availBytes: UInt64 = 0, swapInRatePagesPerSec: Double = 0,
                regimeShiftRecent: Bool = false, thetaCriticalBytes: UInt64 = 0,
                drivers: [String] = []) {
        self.etaMinutesToWarn = etaMinutesToWarn
        self.etaMinutesToCritical = etaMinutesToCritical
        self.etaP10Minutes = etaP10Minutes
        self.pPressure15min = pPressure15min
        self.confidence = confidence
        self.slopeBytesPerSec = slopeBytesPerSec
        self.availBytes = availBytes
        self.swapInRatePagesPerSec = swapInRatePagesPerSec
        self.regimeShiftRecent = regimeShiftRecent
        self.thetaCriticalBytes = thetaCriticalBytes
        self.drivers = drivers
    }
}

public struct Anomaly: Codable {
    public var pid: Int32
    public var name: String
    public var footprintBytes: UInt64
    public var slopeMbPerHour: Double
    public var ceilingBytes: UInt64      // this app's learned normal ceiling
    public var tteHours: Double?         // hours until system avail exhausted at this slope
    public var sustainedMinutes: Double
    public var confidence: String        // "medium" | "high"

    public init(pid: Int32, name: String, footprintBytes: UInt64, slopeMbPerHour: Double,
                ceilingBytes: UInt64, tteHours: Double?, sustainedMinutes: Double,
                confidence: String) {
        self.pid = pid
        self.name = name
        self.footprintBytes = footprintBytes
        self.slopeMbPerHour = slopeMbPerHour
        self.ceilingBytes = ceilingBytes
        self.tteHours = tteHours
        self.sustainedMinutes = sustainedMinutes
        self.confidence = confidence
    }
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
