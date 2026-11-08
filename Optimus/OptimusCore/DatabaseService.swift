import Foundation
import SQLite3

// NOTE: This file is shared between the `Optimus` app target and the `OptimusSampler`
// background-helper target (via dual synchronized-folder membership). Keep it
// Foundation + SQLite3 only — no SwiftUI/AppKit/Observation — so the helper stays lightweight.

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct BatterySampleSnapshot {
    let timestamp: Date
    let chargePercent: Double
    let isCharging: Bool
    let isPluggedIn: Bool
    let amperage: Int
    let voltage: Double
    let temperature: Double
    let cycleCount: Int
    let healthPercent: Double
    let energyMode: String
}

struct BatterySampleRecord {
    let timestamp: Date
    let chargePercent: Double
    let isCharging: Bool
    let isPluggedIn: Bool
    let amperage: Int
    let voltage: Double
    let temperature: Double
    let cycleCount: Int
    let healthPercent: Double
    let energyMode: String
}

struct PowerEventRecord {
    let timestamp: Date
    let eventType: String
    let chargePercent: Double
}

struct SystemSampleSnapshot {
    let timestamp: Date
    let cpuTicksUser: UInt64
    let cpuTicksSystem: UInt64
    let cpuTicksIdle: UInt64
    let cpuTicksNice: UInt64
    let cpuUserPercent: Double?
    let cpuSystemPercent: Double?
    let ramTotalBytes: UInt64
    let ramUsedBytes: UInt64
    let ramWiredBytes: UInt64
    let ramActiveBytes: UInt64
    let ramCompressedBytes: UInt64
    let ramFreeBytes: UInt64
    let diskTotalBytes: Int64
    let diskUsedBytes: Int64
    let diskFreeBytes: Int64
}

struct SystemSampleRecord {
    let timestamp: Date
    let cpuTicksUser: UInt64
    let cpuTicksSystem: UInt64
    let cpuTicksIdle: UInt64
    let cpuTicksNice: UInt64
    let cpuUserPercent: Double?
    let cpuSystemPercent: Double?
    let ramTotalBytes: UInt64
    let ramUsedBytes: UInt64
    let ramWiredBytes: UInt64
    let ramActiveBytes: UInt64
    let ramCompressedBytes: UInt64
    let ramFreeBytes: UInt64
    let diskTotalBytes: Int64
    let diskUsedBytes: Int64
    let diskFreeBytes: Int64
}

/// Row-count + date-range summary for one table, used by the Telemetry tab's storage view.
struct TableStorageSummary {
    let rowCount: Int
    let oldest: Date?
    let newest: Date?
}

/// Simple SQLite wrapper for deletion rollback logs, scan history, and system/battery telemetry.
///
/// Shared by two processes — the `Optimus` GUI and the `OptimusSampler` background helper —
/// both of which open this same file at `~/.optimus_log.sqlite`. WAL mode + a busy timeout
/// (set in `init`) are what make that safe: without them, a write from one process while the
/// other holds the file would fail instantly, and every write path below swallows that
/// failure silently (`guard ... else { return }`), so samples would vanish with no signal.
///
/// Telemetry lives in three tables:
/// - `battery_samples` / `system_samples`: one row every 60 seconds from the background
///   helper. Kept forever — deletion is manual, from the Telemetry tab, never automatic.
/// - `power_events`: one row only when plug/charging state changes between samples.
final class DatabaseService {
    static let shared = DatabaseService()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.optimus.database", qos: .utility)
    private static let iso8601 = ISO8601DateFormatter()

    private init() {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".optimus_log.sqlite").path
        queue.sync {
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
            sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
            createTables()
        }
    }

    deinit { sqlite3_close(db) }

    /// Waits for all writes queued so far to finish. The write queue is serial FIFO,
    /// so scheduling one more block after them and waiting on it guarantees everything
    /// queued earlier has completed. Needed by the one-shot `OptimusSampler` helper,
    /// which must not exit() while `logBatterySample`/`logSystemSample` are still
    /// pending on the background queue — the GUI never needs this, since it stays alive.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS deletion_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            action TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scan_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            total_bytes INTEGER NOT NULL,
            item_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS battery_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            charge_percent REAL NOT NULL,
            is_charging INTEGER NOT NULL,
            is_plugged_in INTEGER NOT NULL,
            amperage INTEGER NOT NULL,
            voltage REAL NOT NULL,
            temperature REAL NOT NULL,
            cycle_count INTEGER NOT NULL,
            health_percent REAL NOT NULL,
            energy_mode TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_battery_samples_timestamp ON battery_samples(timestamp);
        CREATE TABLE IF NOT EXISTS power_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            event_type TEXT NOT NULL,
            charge_percent REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_power_events_timestamp ON power_events(timestamp);
        CREATE TABLE IF NOT EXISTS system_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            cpu_ticks_user INTEGER NOT NULL,
            cpu_ticks_system INTEGER NOT NULL,
            cpu_ticks_idle INTEGER NOT NULL,
            cpu_ticks_nice INTEGER NOT NULL,
            cpu_user_percent REAL,
            cpu_system_percent REAL,
            ram_total_bytes INTEGER NOT NULL,
            ram_used_bytes INTEGER NOT NULL,
            ram_wired_bytes INTEGER NOT NULL,
            ram_active_bytes INTEGER NOT NULL,
            ram_compressed_bytes INTEGER NOT NULL,
            ram_free_bytes INTEGER NOT NULL,
            disk_total_bytes INTEGER NOT NULL,
            disk_used_bytes INTEGER NOT NULL,
            disk_free_bytes INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_system_samples_timestamp ON system_samples(timestamp);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func logDeletion(path: String, sizeBytes: Int64, action: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "INSERT INTO deletion_log (path, size_bytes, timestamp, action) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let ts = Self.iso8601.string(from: Date())
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, sizeBytes)
            sqlite3_bind_text(stmt, 3, ts, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, action, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func logScan(totalBytes: Int64, itemCount: Int) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "INSERT INTO scan_history (timestamp, total_bytes, item_count) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let ts = Self.iso8601.string(from: Date())
            sqlite3_bind_text(stmt, 1, ts, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, totalBytes)
            sqlite3_bind_int(stmt, 3, Int32(itemCount))
            sqlite3_step(stmt)
        }
    }

    // MARK: - Battery telemetry: writes

    func logBatterySample(_ s: BatterySampleSnapshot) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            INSERT INTO battery_samples
            (timestamp, charge_percent, is_charging, is_plugged_in, amperage, voltage, temperature, cycle_count, health_percent, energy_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: s.timestamp), -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, s.chargePercent)
            sqlite3_bind_int(stmt, 3, s.isCharging ? 1 : 0)
            sqlite3_bind_int(stmt, 4, s.isPluggedIn ? 1 : 0)
            sqlite3_bind_int(stmt, 5, Int32(s.amperage))
            sqlite3_bind_double(stmt, 6, s.voltage)
            sqlite3_bind_double(stmt, 7, s.temperature)
            sqlite3_bind_int(stmt, 8, Int32(s.cycleCount))
            sqlite3_bind_double(stmt, 9, s.healthPercent)
            sqlite3_bind_text(stmt, 10, s.energyMode, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func logPowerEvent(type: String, chargePercent: Double, timestamp: Date = Date()) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "INSERT INTO power_events (timestamp, event_type, charge_percent) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: timestamp), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, chargePercent)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Battery telemetry: reads

    /// Fetches raw samples, optionally since a given date (nil = all history).
    /// Aggregation for charts (per-day/hour grouping, bucket sums) happens client-side
    /// in the view model — simpler than hand-written SQL GROUP BY per chart.
    func fetchBatterySamples(since: Date?) async -> [BatterySampleRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let sql: String
                if since != nil {
                    sql = "SELECT timestamp, charge_percent, is_charging, is_plugged_in, amperage, voltage, temperature, cycle_count, health_percent, energy_mode FROM battery_samples WHERE timestamp >= ? ORDER BY timestamp ASC;"
                } else {
                    sql = "SELECT timestamp, charge_percent, is_charging, is_plugged_in, amperage, voltage, temperature, cycle_count, health_percent, energy_mode FROM battery_samples ORDER BY timestamp ASC;"
                }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(stmt) }
                if let since {
                    sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: since), -1, SQLITE_TRANSIENT)
                }

                var results: [BatterySampleRecord] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let tsCStr = sqlite3_column_text(stmt, 0),
                          let ts = Self.iso8601.date(from: String(cString: tsCStr)) else { continue }
                    let energyModeCStr = sqlite3_column_text(stmt, 9)
                    results.append(BatterySampleRecord(
                        timestamp: ts,
                        chargePercent: sqlite3_column_double(stmt, 1),
                        isCharging: sqlite3_column_int(stmt, 2) == 1,
                        isPluggedIn: sqlite3_column_int(stmt, 3) == 1,
                        amperage: Int(sqlite3_column_int(stmt, 4)),
                        voltage: sqlite3_column_double(stmt, 5),
                        temperature: sqlite3_column_double(stmt, 6),
                        cycleCount: Int(sqlite3_column_int(stmt, 7)),
                        healthPercent: sqlite3_column_double(stmt, 8),
                        energyMode: energyModeCStr.map { String(cString: $0) } ?? "Automatic"
                    ))
                }
                continuation.resume(returning: results)
            }
        }
    }

    /// Most recent battery sample, if any. Used by the background helper to derive
    /// deltas/caching (health-check throttling, plug/charge transition detection)
    /// without needing an in-memory previous-run state (the process is one-shot).
    func fetchLatestBatterySample() async -> BatterySampleRecord? {
        await fetchBatterySamples(since: nil).last
    }

    /// Fetches power transition events, optionally since a given date (nil = all history).
    func fetchPowerEvents(since: Date?) async -> [PowerEventRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let sql: String
                if since != nil {
                    sql = "SELECT timestamp, event_type, charge_percent FROM power_events WHERE timestamp >= ? ORDER BY timestamp ASC;"
                } else {
                    sql = "SELECT timestamp, event_type, charge_percent FROM power_events ORDER BY timestamp ASC;"
                }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(stmt) }
                if let since {
                    sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: since), -1, SQLITE_TRANSIENT)
                }

                var results: [PowerEventRecord] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let tsCStr = sqlite3_column_text(stmt, 0),
                          let ts = Self.iso8601.date(from: String(cString: tsCStr)),
                          let typeCStr = sqlite3_column_text(stmt, 1) else { continue }
                    results.append(PowerEventRecord(
                        timestamp: ts,
                        eventType: String(cString: typeCStr),
                        chargePercent: sqlite3_column_double(stmt, 2)
                    ))
                }
                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - System telemetry: writes

    func logSystemSample(_ s: SystemSampleSnapshot) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            INSERT INTO system_samples
            (timestamp, cpu_ticks_user, cpu_ticks_system, cpu_ticks_idle, cpu_ticks_nice, cpu_user_percent, cpu_system_percent,
             ram_total_bytes, ram_used_bytes, ram_wired_bytes, ram_active_bytes, ram_compressed_bytes, ram_free_bytes,
             disk_total_bytes, disk_used_bytes, disk_free_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: s.timestamp), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(bitPattern: s.cpuTicksUser))
            sqlite3_bind_int64(stmt, 3, Int64(bitPattern: s.cpuTicksSystem))
            sqlite3_bind_int64(stmt, 4, Int64(bitPattern: s.cpuTicksIdle))
            sqlite3_bind_int64(stmt, 5, Int64(bitPattern: s.cpuTicksNice))
            if let p = s.cpuUserPercent { sqlite3_bind_double(stmt, 6, p) } else { sqlite3_bind_null(stmt, 6) }
            if let p = s.cpuSystemPercent { sqlite3_bind_double(stmt, 7, p) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_int64(stmt, 8, Int64(bitPattern: s.ramTotalBytes))
            sqlite3_bind_int64(stmt, 9, Int64(bitPattern: s.ramUsedBytes))
            sqlite3_bind_int64(stmt, 10, Int64(bitPattern: s.ramWiredBytes))
            sqlite3_bind_int64(stmt, 11, Int64(bitPattern: s.ramActiveBytes))
            sqlite3_bind_int64(stmt, 12, Int64(bitPattern: s.ramCompressedBytes))
            sqlite3_bind_int64(stmt, 13, Int64(bitPattern: s.ramFreeBytes))
            sqlite3_bind_int64(stmt, 14, s.diskTotalBytes)
            sqlite3_bind_int64(stmt, 15, s.diskUsedBytes)
            sqlite3_bind_int64(stmt, 16, s.diskFreeBytes)
            sqlite3_step(stmt)
        }
    }

    // MARK: - System telemetry: reads

    func fetchSystemSamples(since: Date?) async -> [SystemSampleRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let columns = "timestamp, cpu_ticks_user, cpu_ticks_system, cpu_ticks_idle, cpu_ticks_nice, cpu_user_percent, cpu_system_percent, ram_total_bytes, ram_used_bytes, ram_wired_bytes, ram_active_bytes, ram_compressed_bytes, ram_free_bytes, disk_total_bytes, disk_used_bytes, disk_free_bytes"
                let sql: String
                if since != nil {
                    sql = "SELECT \(columns) FROM system_samples WHERE timestamp >= ? ORDER BY timestamp ASC;"
                } else {
                    sql = "SELECT \(columns) FROM system_samples ORDER BY timestamp ASC;"
                }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(stmt) }
                if let since {
                    sqlite3_bind_text(stmt, 1, Self.iso8601.string(from: since), -1, SQLITE_TRANSIENT)
                }

                var results: [SystemSampleRecord] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let tsCStr = sqlite3_column_text(stmt, 0),
                          let ts = Self.iso8601.date(from: String(cString: tsCStr)) else { continue }
                    let hasUserPct = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                    let hasSysPct = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                    results.append(SystemSampleRecord(
                        timestamp: ts,
                        cpuTicksUser: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
                        cpuTicksSystem: UInt64(bitPattern: sqlite3_column_int64(stmt, 2)),
                        cpuTicksIdle: UInt64(bitPattern: sqlite3_column_int64(stmt, 3)),
                        cpuTicksNice: UInt64(bitPattern: sqlite3_column_int64(stmt, 4)),
                        cpuUserPercent: hasUserPct ? sqlite3_column_double(stmt, 5) : nil,
                        cpuSystemPercent: hasSysPct ? sqlite3_column_double(stmt, 6) : nil,
                        ramTotalBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 7)),
                        ramUsedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 8)),
                        ramWiredBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 9)),
                        ramActiveBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 10)),
                        ramCompressedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 11)),
                        ramFreeBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 12)),
                        diskTotalBytes: sqlite3_column_int64(stmt, 13),
                        diskUsedBytes: sqlite3_column_int64(stmt, 14),
                        diskFreeBytes: sqlite3_column_int64(stmt, 15)
                    ))
                }
                continuation.resume(returning: results)
            }
        }
    }

    /// Most recent system sample, if any. Used by the background helper to compute
    /// CPU tick deltas across one-shot runs (the process has no in-memory previous state).
    func fetchLatestSystemSample() async -> SystemSampleRecord? {
        await fetchSystemSamples(since: nil).last
    }

    // MARK: - Telemetry tab: storage summary + manual deletion

    private static let telemetryTables = ["battery_samples", "system_samples", "power_events"]

    /// Row count + oldest/newest timestamp for one telemetry table, for the Telemetry tab's
    /// storage summary. `table` must be one of `telemetryTables` — not user-supplied, so
    /// string-interpolating it into the query (SQLite has no bind syntax for identifiers) is safe.
    func storageSummary(table: String) async -> TableStorageSummary {
        guard Self.telemetryTables.contains(table) else { return TableStorageSummary(rowCount: 0, oldest: nil, newest: nil) }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: TableStorageSummary(rowCount: 0, oldest: nil, newest: nil))
                    return
                }
                let sql = "SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM \(table);"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(returning: TableStorageSummary(rowCount: 0, oldest: nil, newest: nil))
                    return
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    continuation.resume(returning: TableStorageSummary(rowCount: 0, oldest: nil, newest: nil))
                    return
                }
                let count = Int(sqlite3_column_int64(stmt, 0))
                let oldest = sqlite3_column_text(stmt, 1).flatMap { Self.iso8601.date(from: String(cString: $0)) }
                let newest = sqlite3_column_text(stmt, 2).flatMap { Self.iso8601.date(from: String(cString: $0)) }
                continuation.resume(returning: TableStorageSummary(rowCount: count, oldest: oldest, newest: newest))
            }
        }
    }

    /// Deletes rows from one telemetry table within an optional time range (nil bounds = open-ended).
    /// `table` must be one of `telemetryTables` — see `storageSummary` for why interpolation is safe here.
    @discardableResult
    func deleteTelemetry(table: String, before: Date?, after: Date?) async -> Bool {
        guard Self.telemetryTables.contains(table) else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: false)
                    return
                }
                var clauses: [String] = []
                if after != nil { clauses.append("timestamp >= ?") }
                if before != nil { clauses.append("timestamp <= ?") }
                let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
                let sql = "DELETE FROM \(table) \(whereClause);"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(returning: false)
                    return
                }
                defer { sqlite3_finalize(stmt) }
                var idx: Int32 = 1
                if let after {
                    sqlite3_bind_text(stmt, idx, Self.iso8601.string(from: after), -1, SQLITE_TRANSIENT)
                    idx += 1
                }
                if let before {
                    sqlite3_bind_text(stmt, idx, Self.iso8601.string(from: before), -1, SQLITE_TRANSIENT)
                }
                let ok = sqlite3_step(stmt) == SQLITE_DONE
                continuation.resume(returning: ok)
            }
        }
    }

    func deleteBatterySamples(before: Date? = nil, after: Date? = nil) async {
        await deleteTelemetry(table: "battery_samples", before: before, after: after)
    }

    func deleteSystemSamples(before: Date? = nil, after: Date? = nil) async {
        await deleteTelemetry(table: "system_samples", before: before, after: after)
    }

    func deletePowerEvents(before: Date? = nil, after: Date? = nil) async {
        await deleteTelemetry(table: "power_events", before: before, after: after)
    }
}
