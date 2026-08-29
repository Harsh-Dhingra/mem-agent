import Darwin
import Foundation
import CLibProc

public struct ProcessSweep {
    public var samples: [ProcessSample]
    public var rusageCount: Int
    public var psFallbackCount: Int
    public var unreadableCount: Int
}

public enum ProcessStats {
    /// Sample every process we can see. proc_pid_rusage works for same-uid
    /// processes; pids it refuses are backfilled with RSS from one `ps` run.
    public static func sweep(at date: Date = Date()) -> ProcessSweep {
        let ts = date.timeIntervalSince1970
        var pids = [Int32](repeating: 0, count: 16384)
        let count = memagent_list_pids(&pids, Int32(pids.count))
        guard count > 0 else {
            return ProcessSweep(samples: [], rusageCount: 0, psFallbackCount: 0, unreadableCount: 0)
        }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(Int(count))
        var failed: [Int32] = []

        var nameBuf = [CChar](repeating: 0, count: 256)
        for i in 0..<Int(count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ru = memagent_rusage()
            if memagent_pid_rusage(pid, &ru) == 0 {
                nameBuf[0] = 0
                _ = memagent_pid_name(pid, &nameBuf, UInt32(nameBuf.count))
                let name = nameBuf[0] != 0 ? String(cString: nameBuf) : "pid-\(pid)"
                samples.append(ProcessSample(
                    ts: ts, pid: pid, name: name,
                    footprintBytes: ru.phys_footprint,
                    residentBytes: ru.resident_size,
                    cpuTime: ru.cpu_user &+ ru.cpu_system,
                    source: "rusage"))
            } else {
                failed.append(pid)
            }
        }

        var psCount = 0
        if !failed.isEmpty {
            let psInfo = psSweep()
            for pid in failed {
                if let info = psInfo[pid] {
                    samples.append(ProcessSample(
                        ts: ts, pid: pid, name: info.name,
                        footprintBytes: info.rssBytes,
                        residentBytes: info.rssBytes,
                        cpuTime: 0,
                        source: "ps"))
                    psCount += 1
                }
            }
        }

        return ProcessSweep(
            samples: samples,
            rusageCount: samples.count - psCount,
            psFallbackCount: psCount,
            unreadableCount: failed.count - psCount)
    }

    /// One `ps` invocation covering every process (rss is in KB).
    static func psSweep() -> [Int32: (name: String, rssBytes: UInt64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        var result: [Int32: (String, UInt64)] = [:]
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return result }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let pid = Int32(parts[0]),
                      let rssKB = UInt64(parts[1]) else { continue }
                let comm = String(parts[2])
                let name = (comm as NSString).lastPathComponent
                result[pid] = (name, rssKB * 1024)
            }
        } catch {
            return result
        }
        return result
    }

    /// Group processes by name (Chrome's N helpers roll up into one row).
    public static func group(_ samples: [ProcessSample]) -> [ConsumerGroup] {
        var groups: [String: ConsumerGroup] = [:]
        for s in samples {
            var g = groups[s.name] ?? ConsumerGroup(name: s.name, processCount: 0, footprintBytes: 0, pids: [])
            g.processCount += 1
            g.footprintBytes &+= s.footprintBytes
            g.pids.append(s.pid)
            groups[s.name] = g
        }
        return groups.values.sorted { $0.footprintBytes > $1.footprintBytes }
    }
}
