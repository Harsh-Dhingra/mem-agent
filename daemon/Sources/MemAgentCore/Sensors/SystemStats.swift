import Darwin
import Foundation

public enum SensorError: Error, CustomStringConvertible {
    case mach(String, Int32)
    case sysctl(String, Int32)

    public var description: String {
        switch self {
        case .mach(let call, let code): return "\(call) failed: kern_return \(code)"
        case .sysctl(let name, let errno): return "sysctl \(name) failed: errno \(errno)"
        }
    }
}

public enum SystemStats {
    /// Fraction of inactive pages assumed reclaimable when computing `avail`.
    public static let inactiveReclaimFactor = 0.5

    public static func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }

    public static func totalMemory() throws -> UInt64 {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &len, nil, 0) == 0 else {
            throw SensorError.sysctl("hw.memsize", errno)
        }
        return value
    }

    public static func pressureLevel() -> Int {
        var level: Int32 = 1
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) != 0 {
            return 1
        }
        return Int(level)
    }

    static func swapUsage() throws -> xsw_usage {
        var xsw = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &len, nil, 0) == 0 else {
            throw SensorError.sysctl("vm.swapusage", errno)
        }
        return xsw
    }

    static func vmStatistics() throws -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw SensorError.mach("host_statistics64", kr) }
        return stats
    }

    public static func sample(at date: Date = Date()) throws -> SystemSnapshot {
        let page = pageSize()
        let total = try totalMemory()
        let vm = try vmStatistics()
        let swap = try swapUsage()

        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) &* page }
        func bytes(_ pages: UInt64) -> UInt64 { pages &* page }

        let free = bytes(vm.free_count &- min(vm.free_count, vm.speculative_count))
        let inactive = bytes(vm.inactive_count)
        let purgeable = bytes(vm.purgeable_count)
        let avail = Double(free) + Double(purgeable) + Double(inactive) * inactiveReclaimFactor

        return SystemSnapshot(
            ts: date.timeIntervalSince1970,
            totalBytes: total,
            freeBytes: free,
            activeBytes: bytes(vm.active_count),
            inactiveBytes: inactive,
            wiredBytes: bytes(vm.wire_count),
            compressedBytes: bytes(UInt64(vm.compressor_page_count)),
            purgeableBytes: purgeable,
            externalBytes: bytes(UInt64(vm.external_page_count)),
            internalBytes: bytes(UInt64(vm.internal_page_count)),
            swapTotalBytes: swap.xsu_total,
            swapUsedBytes: swap.xsu_used,
            swapIns: UInt64(vm.swapins),   // cumulative page counts
            swapOuts: UInt64(vm.swapouts),
            pageIns: UInt64(vm.pageins),
            pageOuts: UInt64(vm.pageouts),
            compressions: UInt64(vm.compressions),
            pressureLevel: pressureLevel(),
            availBytes: UInt64(max(0, avail))
        )
    }
}
