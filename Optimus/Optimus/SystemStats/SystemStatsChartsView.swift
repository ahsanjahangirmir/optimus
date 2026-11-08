import SwiftUI
import Charts

private let bytesPerGB = 1_073_741_824.0

@Observable
@MainActor
final class SystemStatsChartsViewModel {
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
    var samples: [SystemSampleRecord] = []
    var isLoading = false

    private let minutesPerSample = 1.0 // matches the background sampler's 60s interval

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        samples = await DatabaseService.shared.fetchSystemSamples(since: range.since)
    }

    /// A single daily bucket is meaningless for a 24h CPU view, so the 24h range groups
    /// by hour instead — everything else still groups by day, matching Battery's charts.
    private var bucketUnit: Calendar.Component { range == .day ? .hour : .day }

    struct BucketPoint: Identifiable {
        let id = UUID()
        let date: Date
        let avg: Double
        let peak: Double
    }

    var cpuByBucket: [BucketPoint] {
        groupedByBucket { arr in
            let totals = arr.compactMap { sample -> Double? in
                guard let u = sample.cpuUserPercent, let s = sample.cpuSystemPercent else { return nil }
                return u + s
            }
            guard !totals.isEmpty else { return (0, 0) }
            return (totals.reduce(0, +) / Double(totals.count), totals.max() ?? 0)
        }
    }

    var ramByBucket: [BucketPoint] {
        groupedByBucket { arr in
            let pcts = arr.map { sample -> Double in
                guard sample.ramTotalBytes > 0 else { return 0 }
                return Double(sample.ramUsedBytes) / Double(sample.ramTotalBytes) * 100
            }
            guard !pcts.isEmpty else { return (0, 0) }
            return (pcts.reduce(0, +) / Double(pcts.count), pcts.max() ?? 0)
        }
    }

    struct MemoryCompositionPoint: Identifiable {
        let id = UUID()
        let date: Date
        let wiredGB: Double
        let activeGB: Double
        let compressedGB: Double
    }

    var memoryCompositionByBucket: [MemoryCompositionPoint] {
        let unit = bucketUnit
        let grouped = Dictionary(grouping: samples) { sample in
            Calendar.current.dateInterval(of: unit, for: sample.timestamp)?.start ?? sample.timestamp
        }
        return grouped.map { date, arr in
            let count = Double(max(arr.count, 1))
            return MemoryCompositionPoint(
                date: date,
                wiredGB: arr.map { Double($0.ramWiredBytes) }.reduce(0, +) / count / bytesPerGB,
                activeGB: arr.map { Double($0.ramActiveBytes) }.reduce(0, +) / count / bytesPerGB,
                compressedGB: arr.map { Double($0.ramCompressedBytes) }.reduce(0, +) / count / bytesPerGB
            )
        }.sorted { $0.date < $1.date }
    }

    struct DiskPoint: Identifiable {
        let id = UUID()
        let day: Date
        let freeGB: Double
    }

    /// Always grouped by day regardless of range — free disk space is a slow-moving metric.
    var freeDiskByDay: [DiskPoint] {
        Dictionary(grouping: samples) { Calendar.current.startOfDay(for: $0.timestamp) }
            .map { day, arr in
                let count = Double(max(arr.count, 1))
                let avgFree = arr.map { Double($0.diskFreeBytes) }.reduce(0, +) / count
                return DiskPoint(day: day, freeGB: avgFree / bytesPerGB)
            }
            .sorted { $0.day < $1.day }
    }

    struct PressureBucket: Identifiable {
        let id = UUID()
        let label: String
        let minutes: Double
    }

    var pressureBuckets: [PressureBucket] {
        func usedPercent(_ s: SystemSampleRecord) -> Double {
            s.ramTotalBytes > 0 ? Double(s.ramUsedBytes) / Double(s.ramTotalBytes) * 100 : 0
        }
        let comfortable = samples.filter { usedPercent($0) < 65 }.count
        let busy = samples.filter { let p = usedPercent($0); return p >= 65 && p <= 85 }.count
        let pressured = samples.filter { usedPercent($0) > 85 }.count
        return [
            PressureBucket(label: "Comfortable (<65%)", minutes: Double(comfortable) * minutesPerSample),
            PressureBucket(label: "Busy (65–85%)", minutes: Double(busy) * minutesPerSample),
            PressureBucket(label: "Under pressure (>85%)", minutes: Double(pressured) * minutesPerSample)
        ]
    }

    private func groupedByBucket(_ reducer: ([SystemSampleRecord]) -> (avg: Double, peak: Double)) -> [BucketPoint] {
        let unit = bucketUnit
        let grouped = Dictionary(grouping: samples) { sample in
            Calendar.current.dateInterval(of: unit, for: sample.timestamp)?.start ?? sample.timestamp
        }
        return grouped.map { date, arr in
            let (avg, peak) = reducer(arr)
            return BucketPoint(date: date, avg: avg, peak: peak)
        }.sorted { $0.date < $1.date }
    }
}

struct SystemStatsChartsView: View {
    @State private var vm = SystemStatsChartsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Range", selection: $vm.range) {
                ForEach(SystemStatsChartsViewModel.Range.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)

            InfoCard(title: "CPU Usage Over Time",
                     tooltip: "Average and peak CPU usage in each period. The peak line surfaces spikes you weren't watching for — a high average with a much higher peak means occasional heavy bursts rather than steady load.") {
                chartOrEmptyState(vm.cpuByBucket) {
                    Chart(vm.cpuByBucket) { point in
                        LineMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("Average", point.avg))
                            .foregroundStyle(by: .value("Series", "Average"))
                        LineMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("Peak", point.peak))
                            .foregroundStyle(by: .value("Series", "Peak"))
                    }
                    .chartYScale(domain: 0...100)
                }
            }

            InfoCard(title: "Memory Usage Over Time",
                     tooltip: "Average and peak percentage of RAM in use in each period.") {
                chartOrEmptyState(vm.ramByBucket) {
                    Chart(vm.ramByBucket) { point in
                        LineMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("Average", point.avg))
                            .foregroundStyle(by: .value("Series", "Average"))
                        LineMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("Peak", point.peak))
                            .foregroundStyle(by: .value("Series", "Peak"))
                    }
                    .chartYScale(domain: 0...100)
                }
            }

            InfoCard(title: "Memory Composition Over Time",
                     tooltip: "How your used memory breaks down between Wired, Active, and Compressed, in gigabytes. Watching Compressed grow over time is a better early sign of memory pressure than the total alone.") {
                chartOrEmptyState(vm.memoryCompositionByBucket) {
                    Chart(vm.memoryCompositionByBucket) { point in
                        AreaMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("GB", point.wiredGB))
                            .foregroundStyle(by: .value("Segment", "Wired"))
                        AreaMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("GB", point.activeGB))
                            .foregroundStyle(by: .value("Segment", "Active"))
                        AreaMark(x: .value("Time", point.date, unit: vm.range == .day ? .hour : .day), y: .value("GB", point.compressedGB))
                            .foregroundStyle(by: .value("Segment", "Compressed"))
                    }
                }
            }

            InfoCard(title: "Free Disk Space Over Time",
                     tooltip: "How much free space is left on your startup disk, day by day. A steady downward slope tells you roughly when you'll run out.") {
                chartOrEmptyState(vm.freeDiskByDay) {
                    Chart(vm.freeDiskByDay) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Free GB", point.freeGB))
                    }
                }
            }

            InfoCard(title: "Time Under Memory Pressure",
                     tooltip: "Time spent comfortable, busy, or genuinely under memory pressure, based on how full RAM was at each sample.") {
                chartOrEmptyState(vm.pressureBuckets) {
                    Chart(vm.pressureBuckets) { b in
                        BarMark(x: .value("Level", b.label), y: .value("Minutes", b.minutes))
                            .foregroundStyle(by: .value("Level", b.label))
                    }
                }
            }
        }
        .task { await vm.reload() }
    }

    @ViewBuilder
    private func chartOrEmptyState<T, Content: View>(_ data: [T], @ViewBuilder chart: () -> Content) -> some View {
        if data.isEmpty {
            Text(vm.isLoading ? "Loading…" : "Not enough data yet — turn on background collection in Telemetry, then check back in a few minutes.")
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
    SystemStatsChartsView().frame(width: 700).padding()
}
