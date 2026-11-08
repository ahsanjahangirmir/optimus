import Foundation
import Observation
import Darwin

struct CPULoad {
    var userPercent: Double = 0
    var systemPercent: Double = 0
    var idlePercent: Double = 0
    var totalUsed: Double { userPercent + systemPercent }
}

struct ProcessStat: Identifiable {
    var id: Int32
    var name: String
    var cpuPercent: Double
    var memoryBytes: UInt64
}

private let procPathInfoMax = 4096
/// ~2 minutes of history at the 2s live-poll interval — enough for a small sparkline.
private let ringBufferCapacity = 60

@Observable
@MainActor
final class SystemStatsService {
    var cpu = CPULoad()
    var ram = RAMInfo()
    var disk = DiskInfo()
    /// Full process list, unsorted and untruncated — the view derives "top by memory"
    /// and "top by CPU" from this so both sort orders are available.
    var processes: [ProcessStat] = []
    var loadAverage: (one: Double, five: Double, fifteen: Double) = (0, 0, 0)
    let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

    /// Live-only trailing history for the gauge sparklines. Never persisted —
    /// durable history comes from the background sampler's database rows instead.
    var recentCPU: [Double] = []
    var recentRAM: [Double] = []

    private var prevTicks = CPUTicks()
    private var prevProcCPUNanos: [pid_t: UInt64] = [:]
    private var prevProcSampleDate: Date?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        cpu = readCPU()
        ram = SystemProbe.readRAM()
        disk = SystemProbe.readDisk()
        processes = readProcesses()
        loadAverage = Self.readLoadAverage()

        appendRing(&recentCPU, cpu.totalUsed)
        appendRing(&recentRAM, ram.pressure * 100)
    }

    private func appendRing(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > ringBufferCapacity {
            buffer.removeFirst(buffer.count - ringBufferCapacity)
        }
    }

    private func readCPU() -> CPULoad {
        let ticks = SystemProbe.readCPUTicks()

        let du = ticks.user - prevTicks.user
        let ds = ticks.system - prevTicks.system
        let di = ticks.idle - prevTicks.idle
        let dn = ticks.nice - prevTicks.nice
        let dt = du + ds + di + dn

        prevTicks = ticks
        guard dt > 0 else { return CPULoad() }

        return CPULoad(
            userPercent:   Double(du + dn) / Double(dt) * 100,
            systemPercent: Double(ds)      / Double(dt) * 100,
            idlePercent:   Double(di)      / Double(dt) * 100
        )
    }

    private static func readLoadAverage() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    /// Per-process CPU% is a delta of `proc_taskinfo`'s cumulative user+system time
    /// (nanoseconds) against wall-clock time since the previous poll — the same trick
    /// `readCPU()` uses for the system-wide figure. The first poll after `start()` has
    /// no baseline, so every process reads 0% once and self-corrects on the next tick.
    private func readProcesses() -> [ProcessStat] {
        let neededCount = proc_listallpids(nil, 0)
        guard neededCount > 0 else { return [] }
        let capacity = Int(neededCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        let now = Date()
        let elapsed = prevProcSampleDate.map { now.timeIntervalSince($0) } ?? 0
        var newCPUNanos: [pid_t: UInt64] = [:]
        var results: [ProcessStat] = []

        for i in 0..<Int(n) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ti = proc_taskinfo()
            let sz = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sz) == sz else { continue }

            var buf = [CChar](repeating: 0, count: procPathInfoMax)
            proc_name(pid, &buf, UInt32(procPathInfoMax))
            let name = String(cString: buf).components(separatedBy: "/").last ?? ""

            let cpuNanos = ti.pti_total_user + ti.pti_total_system
            newCPUNanos[pid] = cpuNanos

            var cpuPercent = 0.0
            if elapsed > 0, let prevNanos = prevProcCPUNanos[pid], cpuNanos >= prevNanos {
                let deltaSeconds = Double(cpuNanos - prevNanos) / 1_000_000_000.0
                cpuPercent = deltaSeconds / elapsed * 100
            }

            results.append(ProcessStat(
                id: pid,
                name: name.isEmpty ? "pid \(pid)" : name,
                cpuPercent: cpuPercent,
                memoryBytes: ti.pti_resident_size
            ))
        }

        // Rebuilt fresh each pass — dead pids simply drop out, no separate cleanup needed.
        prevProcCPUNanos = newCPUNanos
        prevProcSampleDate = now
        return results
    }
}

func formatBytes(_ bytes: some BinaryInteger) -> String {
    let b = Int64(bytes)
    if b < 1024 { return "\(b) B" }
    let kb = Double(b) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    if mb < 1024 { return String(format: "%.1f MB", mb) }
    return String(format: "%.2f GB", mb / 1024)
}
