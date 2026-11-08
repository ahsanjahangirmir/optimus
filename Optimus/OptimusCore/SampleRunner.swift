import Foundation

/// One-shot sampling orchestration used by the `OptimusSampler` background helper's
/// `main.swift`. Each run: read the previous DB row (there is no in-memory state — the
/// process starts fresh every invocation), probe current values, compute deltas where
/// needed, insert one row per table, then `flush()` before the process exits.
enum SampleRunner {
    /// Must match the plist's `StartInterval`.
    static let sampleInterval: TimeInterval = 60

    /// How stale the previous battery sample can be before paying for a fresh
    /// `system_profiler` health read (~0.3-1s) instead of reusing the cached value.
    private static let healthCheckThreshold: TimeInterval = 60 * 60

    /// How stale the previous system sample can be before its CPU ticks are considered
    /// too old to diff against (e.g. the Mac was asleep, or background sampling was off
    /// for a while) — beyond this, cpu_user_percent/cpu_system_percent are left NULL
    /// rather than averaging across the gap as if it were one normal 60s interval.
    private static let cpuGapThreshold: TimeInterval = 60 * 3

    static func run() async {
        let now = Date()
        await sampleBattery(now: now)
        await sampleSystem(now: now)
        await DatabaseService.shared.flush()
    }

    private static func sampleBattery(now: Date) async {
        let live = BatteryProbe.readLive()
        // Desktops (no battery) report both as 0 — nothing meaningful to sample.
        guard live.maxCapacity > 0 || live.cycleCount > 0 else { return }

        let previous = await DatabaseService.shared.fetchLatestBatterySample()

        var healthPercent = previous?.healthPercent ?? 0
        let shouldRefreshHealth = previous == nil
            || now.timeIntervalSince(previous!.timestamp) > healthCheckThreshold
        if shouldRefreshHealth {
            let (_, health) = await BatteryProbe.readHealth()
            if let health { healthPercent = health }
        }

        if let previous, previous.isPluggedIn != live.isPluggedIn {
            DatabaseService.shared.logPowerEvent(
                type: live.isPluggedIn ? "plugged_in" : "unplugged",
                chargePercent: live.chargePercent,
                timestamp: now
            )
        }
        if let previous, previous.isCharging != live.isCharging {
            DatabaseService.shared.logPowerEvent(
                type: live.isCharging ? "charging_started" : "charging_stopped",
                chargePercent: live.chargePercent,
                timestamp: now
            )
        }

        let energyMode = await PowerModeProbe.readCurrentModeName()

        DatabaseService.shared.logBatterySample(BatterySampleSnapshot(
            timestamp: now,
            chargePercent: live.chargePercent,
            isCharging: live.isCharging,
            isPluggedIn: live.isPluggedIn,
            amperage: live.amperage,
            voltage: live.voltage,
            temperature: live.temperature,
            cycleCount: live.cycleCount,
            healthPercent: healthPercent,
            energyMode: energyMode
        ))
    }

    private static func sampleSystem(now: Date) async {
        let previous = await DatabaseService.shared.fetchLatestSystemSample()
        let ticks = SystemProbe.readCPUTicks()
        let ram = SystemProbe.readRAM()
        let disk = SystemProbe.readDisk()

        var userPercent: Double?
        var systemPercent: Double?

        if let previous,
           now.timeIntervalSince(previous.timestamp) <= cpuGapThreshold,
           ticks.user >= previous.cpuTicksUser,
           ticks.system >= previous.cpuTicksSystem,
           ticks.idle >= previous.cpuTicksIdle,
           ticks.nice >= previous.cpuTicksNice {
            let du = ticks.user - previous.cpuTicksUser
            let ds = ticks.system - previous.cpuTicksSystem
            let di = ticks.idle - previous.cpuTicksIdle
            let dn = ticks.nice - previous.cpuTicksNice
            let dt = du + ds + di + dn
            if dt > 0 {
                userPercent = Double(du + dn) / Double(dt) * 100
                systemPercent = Double(ds) / Double(dt) * 100
            }
        }

        DatabaseService.shared.logSystemSample(SystemSampleSnapshot(
            timestamp: now,
            cpuTicksUser: ticks.user,
            cpuTicksSystem: ticks.system,
            cpuTicksIdle: ticks.idle,
            cpuTicksNice: ticks.nice,
            cpuUserPercent: userPercent,
            cpuSystemPercent: systemPercent,
            ramTotalBytes: ram.totalBytes,
            ramUsedBytes: ram.usedBytes,
            ramWiredBytes: ram.wiredBytes,
            ramActiveBytes: ram.activeBytes,
            ramCompressedBytes: ram.compressedBytes,
            ramFreeBytes: ram.freeBytes,
            diskTotalBytes: disk.totalBytes,
            diskUsedBytes: disk.usedBytes,
            diskFreeBytes: disk.freeBytes
        ))
    }
}
