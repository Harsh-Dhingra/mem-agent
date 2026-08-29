import Foundation
import MemAgentCore

enum SnapshotCommand {
    struct Output: Codable {
        var system: SystemSnapshot
        var topConsumers: [ConsumerGroup]
        var processCoverage: Coverage
        struct Coverage: Codable {
            var rusage: Int
            var psFallback: Int
            var unreadable: Int
        }
    }

    static func run(json: Bool) throws {
        let system = try SystemStats.sample()
        let sweep = ProcessStats.sweep()
        let groups = ProcessStats.group(sweep.samples)

        if json {
            let out = Output(
                system: system,
                topConsumers: Array(groups.prefix(25)),
                processCoverage: .init(rusage: sweep.rusageCount,
                                       psFallback: sweep.psFallbackCount,
                                       unreadable: sweep.unreadableCount))
            print(try JSON.encodeString(out, pretty: true))
            return
        }

        let s = system
        print("MEMORY  \(formatBytes(s.usedBytes)) / \(formatBytes(s.totalBytes)) used    pressure: \(s.pressure.label)")
        print("free \(formatBytes(s.freeBytes)) | inactive \(formatBytes(s.inactiveBytes)) | wired \(formatBytes(s.wiredBytes)) | compressed \(formatBytes(s.compressedBytes))")
        print("swap \(formatBytes(s.swapUsedBytes)) / \(formatBytes(s.swapTotalBytes)) used")
        print("avail (est) \(formatBytes(s.availBytes))")
        print("")
        print("TOP CONSUMERS (grouped by app)")
        for g in groups.prefix(15) {
            let procs = g.processCount == 1 ? "" : " (\(g.processCount) procs)"
            print("  \(formatBytes(g.footprintBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(g.name)\(procs)")
        }
        print("")
        print("coverage: \(sweep.rusageCount) via rusage, \(sweep.psFallbackCount) via ps, \(sweep.unreadableCount) unreadable")
    }
}
