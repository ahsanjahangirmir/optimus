import SwiftUI
import Charts

/// Loads samples for the selected range and derives every chart's data from
/// them. All aggregation happens here in Swift rather than in SQL — at a
/// 5-minute sampling interval, even a full year of raw history is only
/// ~100k rows, small enough that this is simpler to read and change than
/// per-chart SQL, while still keeping the raw table untouched (per your
/// "keep forever" choice).
@Observable
@MainActor
final class BatteryChartsViewModel {
    enum Range: String, CaseIterable, Identifiable {
        case day = "24h", week = "7d", month = "30d", all = "All"
        var id: String { rawValue }

        var since: Date? {
            let cal = Calendar.current
            switch self {
            case .day: return cal.date(byAdding: .day, value: -1, to: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    var range: Range = .week {
        didSet { Task { await reload() } }
    }
    var samples: [BatterySampleRecord] = []
    var isLoading = false

    private let minutesPerSample = 1.0 // matches the background sampler's 60s interval

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        samples = await DatabaseService.shared.fetchBatterySamples(since: range.since)
    }

    struct DayPoint: Identifiable {
        let id = UUID()
        let day: Date
        let value: Double
    }

    var cycleCountByDay: [DayPoint] {
        groupedByDay { arr in Double(arr.map(\.cycleCount).max() ?? 0) }
    }

    var healthByDay: [DayPoint] {
        groupedByDay { arr in
            guard !arr.isEmpty else { return 0 }
            return arr.map(\.healthPercent).reduce(0, +) / Double(arr.count)
        }
    }

    struct PowerSourceDay: Identifiable {
        let id = UUID()
        let day: Date
        let acMinutes: Double
        let batteryMinutes: Double
    }

    var powerSourceByDay: [PowerSourceDay] {
        let grouped = Dictionary(grouping: samples) { Calendar.current.startOfDay(for: $0.timestamp) }
        return grouped.map { day, arr in
            PowerSourceDay(
                day: day,
                acMinutes: Double(arr.filter(\.isPluggedIn).count) * minutesPerSample,
                batteryMinutes: Double(arr.filter { !$0.isPluggedIn }.count) * minutesPerSample
            )
        }.sorted { $0.day < $1.day }
    }

    struct ChargeBucket: Identifiable {
        let id = UUID()
        let label: String
        let minutes: Double
    }

    var chargeBuckets: [ChargeBucket] {
        let low = samples.filter { $0.chargePercent < 20 }.count
        let mid = samples.filter { $0.chargePercent >= 20 && $0.chargePercent <= 80 }.count
        let high = samples.filter { $0.chargePercent > 80 }.count
        return [
            ChargeBucket(label: "Below 20%", minutes: Double(low) * minutesPerSample),
            ChargeBucket(label: "20–80% (healthy)", minutes: Double(mid) * minutesPerSample),
            ChargeBucket(label: "Above 80%", minutes: Double(high) * minutesPerSample)
        ]
    }

    struct ModeUsage: Identifiable {
        let id = UUID()
        let mode: String
        let minutes: Double
    }

    var energyModeUsage: [ModeUsage] {
        Dictionary(grouping: samples, by: \.energyMode)
            .map { mode, arr in ModeUsage(mode: mode, minutes: Double(arr.count) * minutesPerSample) }
            .sorted { $0.minutes > $1.minutes }
    }

    private func groupedByDay(_ reducer: ([BatterySampleRecord]) -> Double) -> [DayPoint] {
        Dictionary(grouping: samples) { Calendar.current.startOfDay(for: $0.timestamp) }
            .map { DayPoint(day: $0.key, value: reducer($0.value)) }
            .sorted { $0.day < $1.day }
    }
}

struct BatteryChartsView: View {
    @State private var vm = BatteryChartsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Range", selection: $vm.range) {
                ForEach(BatteryChartsViewModel.Range.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)

            InfoCard(title: "Cycle Count Over Time",
                     tooltip: "How many charge cycles you've used up, day by day. Watching the slope tells you how fast you're burning through the battery's rated cycle life.") {
                chartOrEmptyState(vm.cycleCountByDay) {
                    Chart(vm.cycleCountByDay) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Cycles", point.value))
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Cycles", point.value))
                    }
                }
            }

            InfoCard(title: "Battery Health Over Time",
                     tooltip: "How your battery's maximum capacity has changed day to day. A slow, steady decline is normal aging; a sudden drop is worth investigating.") {
                chartOrEmptyState(vm.healthByDay) {
                    Chart(vm.healthByDay) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Health %", point.value))
                    }
                    .chartYScale(domain: 0...100)
                }
            }

            InfoCard(title: "AC Power vs Battery",
                     tooltip: "How much of each day you spent plugged into the wall versus running on battery power.") {
                chartOrEmptyState(vm.powerSourceByDay) {
                    Chart(vm.powerSourceByDay) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.acMinutes))
                            .foregroundStyle(by: .value("Source", "AC Power"))
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.batteryMinutes))
                            .foregroundStyle(by: .value("Source", "Battery"))
                    }
                }
            }

            InfoCard(title: "Time in Charge Range",
                     tooltip: "Time spent below 20%, in the 20–80% \"healthy\" range, and above 80%. Batteries age faster when they spend a lot of time near empty or sitting fully charged, so more time in the middle band is gentler on long-term health.") {
                chartOrEmptyState(vm.chargeBuckets) {
                    Chart(vm.chargeBuckets) { b in
                        BarMark(x: .value("Range", b.label), y: .value("Minutes", b.minutes))
                            .foregroundStyle(by: .value("Range", b.label))
                    }
                }
            }

            InfoCard(title: "Energy Mode Usage",
                     tooltip: "How much time was spent in each Energy Mode (Automatic, Low Power, High Power) over the selected range.") {
                chartOrEmptyState(vm.energyModeUsage) {
                    Chart(vm.energyModeUsage) { m in
                        BarMark(x: .value("Mode", m.mode), y: .value("Minutes", m.minutes))
                            .foregroundStyle(by: .value("Mode", m.mode))
                    }
                }
            }
        }
        .task { await vm.reload() }
    }

    /// Every chart shares this so a fresh install (no history yet) shows a
    /// plain message instead of a confusing blank axis grid.
    @ViewBuilder
    private func chartOrEmptyState<T, Content: View>(_ data: [T], @ViewBuilder chart: () -> Content) -> some View {
        if data.isEmpty {
            Text(vm.isLoading ? "Loading…" : "Not enough data yet — check back in a few minutes.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(height: 160, alignment: .center)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else {
            chart()
                .frame(height: 160)
                .padding(16)
        }
    }
}

#Preview {
    BatteryChartsView().frame(width: 700).padding()
}
