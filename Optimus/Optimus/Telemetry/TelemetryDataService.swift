import Foundation
import Observation

@Observable
@MainActor
final class TelemetryDataService {
    var batterySummary = TableStorageSummary(rowCount: 0, oldest: nil, newest: nil)
    var systemSummary = TableStorageSummary(rowCount: 0, oldest: nil, newest: nil)
    var powerEventsSummary = TableStorageSummary(rowCount: 0, oldest: nil, newest: nil)
    var isBusy = false

    func refresh() async {
        async let battery = DatabaseService.shared.storageSummary(table: "battery_samples")
        async let system = DatabaseService.shared.storageSummary(table: "system_samples")
        async let events = DatabaseService.shared.storageSummary(table: "power_events")
        batterySummary = await battery
        systemSummary = await system
        powerEventsSummary = await events
    }

    /// Deletes telemetry older than `cutoff` across all three tables (nil = delete everything).
    func deleteData(before cutoff: Date?) async {
        isBusy = true
        defer { isBusy = false }
        await DatabaseService.shared.deleteBatterySamples(before: cutoff)
        await DatabaseService.shared.deleteSystemSamples(before: cutoff)
        await DatabaseService.shared.deletePowerEvents(before: cutoff)
        await refresh()
    }
}
