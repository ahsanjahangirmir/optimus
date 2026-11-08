import Foundation
import Darwin

struct CPUTicks {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0
}

struct RAMInfo {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var pressure: Double = 0
}

struct DiskInfo {
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var usedPercent: Double = 0
    var mountPoint: String = "/"
}

/// Stateless system reads, shared by the `Optimus` GUI (live gauges, polled every 2s,
/// which keeps its own in-memory tick delta) and the `OptimusSampler` background helper
/// (one durable sample every 60s, which diffs against the previous database row instead).
enum SystemProbe {
    private static let cpuLoadInfoCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    private static let vmInfo64Count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

    /// Raw cumulative tick counts since boot — callers compute their own delta.
    static func readCPUTicks() -> CPUTicks {
        var info = host_cpu_load_info()
        var count = cpuLoadInfoCount
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buf in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, buf, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return CPUTicks() }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func readRAM() -> RAMInfo {
        var vmStats = vm_statistics64()
        var count = vmInfo64Count
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buf in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, buf, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return RAMInfo() }

        let pg     = UInt64(vm_page_size)
        let total  = ProcessInfo.processInfo.physicalMemory
        let wired  = UInt64(vmStats.wire_count)          * pg
        let active = UInt64(vmStats.active_count)        * pg
        let comp   = UInt64(vmStats.compressor_page_count) * pg
        let free   = UInt64(vmStats.free_count)          * pg
        let used   = wired + active + comp

        return RAMInfo(totalBytes: total, usedBytes: used, wiredBytes: wired,
                       activeBytes: active, compressedBytes: comp, freeBytes: free,
                       pressure: Double(used) / Double(total))
    }

    static func readDisk() -> DiskInfo {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return DiskInfo() }
        let block = Int64(fs.f_bsize)
        let total = Int64(fs.f_blocks) * block
        let free  = Int64(fs.f_bavail) * block
        let used  = total - free
        return DiskInfo(totalBytes: total, usedBytes: used, freeBytes: free,
                        usedPercent: total > 0 ? Double(used) / Double(total) * 100 : 0,
                        mountPoint: "/")
    }
}
