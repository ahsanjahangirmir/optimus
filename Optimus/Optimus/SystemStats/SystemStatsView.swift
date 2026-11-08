import SwiftUI
import AppKit
import Charts

struct SystemStatsView: View {
    @State private var service = SystemStatsService()
    @State private var processControl = ProcessControlService()
    @State private var sortByCPU = false
    @State private var killTarget: ProcessStat?
    @State private var killForce = false
    @State private var hoveredPID: Int32?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    GaugeCard(title: "CPU", value: service.cpu.totalUsed, unit: "%", color: cpuColor, icon: "cpu",
                              subtitle: "\(service.activeProcessorCount) cores · load \(String(format: "%.1f", service.loadAverage.one))",
                              tooltip: "How much of your CPU's total capacity is in use right now, averaged across all cores.",
                              history: service.recentCPU)
                    GaugeCard(title: "RAM", value: service.ram.pressure * 100, unit: "%", color: ramColor, icon: "memorychip",
                              subtitle: "\(formatBytes(service.ram.usedBytes)) / \(formatBytes(service.ram.totalBytes))",
                              tooltip: "How much of your Mac's physical memory is currently in use.",
                              history: service.recentRAM)
                    GaugeCard(title: "Disk", value: service.disk.usedPercent, unit: "%", color: diskColor, icon: "internaldrive",
                              subtitle: "\(formatBytes(service.disk.usedBytes)) / \(formatBytes(service.disk.totalBytes))",
                              tooltip: "How much of your startup disk's total capacity is currently used.",
                              history: nil)
                }
                cpuCard
                ramCard
                diskCard
                processesCard
                SystemStatsChartsView()
            }
            .padding(24)
        }
        .navigationTitle("CPU / RAM / SSD")
        .onAppear  { service.start() }
        .onDisappear { service.stop() }
        .alert(
            killTarget.map { "\(killForce ? "Force Quit" : "Quit") \($0.name)?" } ?? "",
            isPresented: Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
        ) {
            Button("Cancel", role: .cancel) { killTarget = nil }
            Button(killForce ? "Force Quit" : "Quit", role: .destructive) {
                if let target = killTarget {
                    processControl.terminate(pid: target.id, name: target.name, force: killForce) {
                        service.refresh()
                    }
                }
                killTarget = nil
            }
        } message: {
            if let target = killTarget {
                if isCriticalProcess(pid: target.id, name: target.name) {
                    Text("\(target.name) (PID \(target.id)) is a core macOS process. Force quitting it can log you out or crash your Mac.")
                } else {
                    Text("\(target.name) (PID \(target.id)) will be \(killForce ? "force quit" : "asked to quit"). Any unsaved work in it will be lost.")
                }
            }
        }
    }

    private var cpuCard: some View {
        InfoCard(title: "CPU") {
            CompositionBar(segments: [
                CompositionSegment(label: "User", value: service.cpu.userPercent, color: .blue),
                CompositionSegment(label: "System", value: service.cpu.systemPercent, color: .orange),
                CompositionSegment(label: "Idle", value: service.cpu.idlePercent, color: .gray.opacity(0.25))
            ])
            .padding(.horizontal, 16)
            .padding(.top, 10)

            InfoRow("User", value: String(format: "%.1f%%", service.cpu.userPercent),
                    tooltip: "CPU time spent running your apps and their code.")
            InfoRow("System", value: String(format: "%.1f%%", service.cpu.systemPercent),
                    tooltip: "CPU time spent inside the kernel doing work on behalf of apps — file I/O, memory management, and so on.")
            InfoRow("Idle", value: String(format: "%.1f%%", service.cpu.idlePercent),
                    tooltip: "CPU time not being used by anything right now.")
            InfoRow("Total Active", value: String(format: "%.1f%%", service.cpu.totalUsed),
                    tooltip: "User + System combined — how busy your CPU is overall.")
            InfoRow("Load Average", value: String(format: "%.2f, %.2f, %.2f", service.loadAverage.one, service.loadAverage.five, service.loadAverage.fifteen),
                    tooltip: "The average number of processes waiting for CPU time, over the last 1, 5, and 15 minutes. Staying below your core count (\(service.activeProcessorCount) on this Mac) generally means the system isn't CPU-bound.")
        }
    }

    private var ramCard: some View {
        InfoCard(title: "Memory") {
            CompositionBar(segments: [
                CompositionSegment(label: "Wired", value: Double(service.ram.wiredBytes), color: .red),
                CompositionSegment(label: "Active", value: Double(service.ram.activeBytes), color: .blue),
                CompositionSegment(label: "Compressed", value: Double(service.ram.compressedBytes), color: .orange),
                CompositionSegment(label: "Free", value: Double(service.ram.freeBytes), color: .gray.opacity(0.25))
            ])
            .padding(.horizontal, 16)
            .padding(.top, 10)

            InfoRow("Total", value: formatBytes(service.ram.totalBytes),
                    tooltip: "Total physical memory installed in this Mac.")
            InfoRow("Used", value: formatBytes(service.ram.usedBytes),
                    tooltip: "Wired + Active + Compressed memory. This won't exactly match Activity Monitor's \"Memory Used\", which also factors in inactive and purgeable pages this app doesn't count.")
            InfoRow("Wired", value: formatBytes(service.ram.wiredBytes),
                    tooltip: "Memory the kernel has locked in place and can't page out — always in use, no matter what else is running.")
            InfoRow("Active", value: formatBytes(service.ram.activeBytes),
                    tooltip: "Memory currently being used by your running apps.")
            InfoRow("Compressed", value: formatBytes(service.ram.compressedBytes),
                    tooltip: "Memory macOS has squeezed to free up space instead of swapping to disk. A little is normal; a large, persistently growing amount means you're genuinely short on RAM.")
            InfoRow("Free", value: formatBytes(service.ram.freeBytes),
                    tooltip: "Memory not currently being used for anything.")
        }
    }

    private var diskCard: some View {
        InfoCard(title: "Storage (\(service.disk.mountPoint))") {
            CompositionBar(segments: [
                CompositionSegment(label: "Used", value: Double(service.disk.usedBytes), color: diskColor),
                CompositionSegment(label: "Free", value: Double(service.disk.freeBytes), color: .gray.opacity(0.25))
            ])
            .padding(.horizontal, 16)
            .padding(.top, 10)

            InfoRow("Total", value: formatBytes(service.disk.totalBytes),
                    tooltip: "Total capacity of your startup disk.")
            InfoRow("Used", value: formatBytes(service.disk.usedBytes),
                    tooltip: "Space currently used by files on your startup disk.")
            InfoRow("Free", value: formatBytes(service.disk.freeBytes),
                    tooltip: "Space available for new files. This reads a little lower than Finder's \"Available\" figure, since it excludes reclaimable purgeable space that Finder counts as free.")
            InfoRow("% Used", value: String(format: "%.1f%%", service.disk.usedPercent),
                    tooltip: "How full your startup disk is, as a percentage of total capacity.")
        }
    }

    private var sortedProcesses: [ProcessStat] {
        let sorted = sortByCPU
            ? service.processes.sorted { $0.cpuPercent > $1.cpuPercent }
            : service.processes.sorted { $0.memoryBytes > $1.memoryBytes }
        return Array(sorted.prefix(20))
    }

    private var processesCard: some View {
        InfoCard(title: "Top Processes by \(sortByCPU ? "CPU" : "Memory")",
                 tooltip: "The 20 processes using the most \(sortByCPU ? "CPU" : "memory") right now. Hover a row (or right-click it) to quit it.") {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Sort", selection: $sortByCPU) {
                    Text("Memory").tag(false)
                    Text("CPU").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                HStack {
                    Text("Process").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    Text("CPU").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Text("Memory").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Color.clear.frame(width: 24)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                Divider()

                ForEach(sortedProcesses) { p in
                    processRow(p)
                }

                if processControl.isApplying, let name = processControl.targetName {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Quitting \(name) — you may be asked to authenticate…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }

                if let error = processControl.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func processRow(_ p: ProcessStat) -> some View {
        HStack {
            Text(p.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.id)").foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            Text(String(format: "%.1f%%", p.cpuPercent)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(formatBytes(p.memoryBytes)).fontWeight(.medium).frame(width: 90, alignment: .trailing)
            Group {
                if hoveredPID == p.id {
                    Button {
                        killForce = false
                        killTarget = p
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 24)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(hoveredPID == p.id ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering in hoveredPID = hovering ? p.id : (hoveredPID == p.id ? nil : hoveredPID) }
        .contextMenu {
            Button("Quit") { killForce = false; killTarget = p }
            Button("Force Quit", role: .destructive) { killForce = true; killTarget = p }
            Divider()
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.id)", forType: .string)
            }
        }
    }

    private var cpuColor: Color { service.cpu.totalUsed > 80 ? .red : service.cpu.totalUsed > 50 ? .orange : .green }
    private var ramColor: Color { service.ram.pressure > 0.85 ? .red : service.ram.pressure > 0.65 ? .orange : .green }
    private var diskColor: Color { service.disk.usedPercent > 90 ? .red : service.disk.usedPercent > 80 ? .orange : .blue }
}

// MARK: - Composition bar

struct CompositionSegment: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let color: Color
}

struct CompositionBar: View {
    let segments: [CompositionSegment]
    var height: CGFloat = 10

    private var total: Double { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    if segment.value > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.color)
                            .frame(width: max(geo.size.width * CGFloat(segment.value / max(total, 1)), 2))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Gauge card

struct GaugeCard: View {
    let title: String
    let value: Double
    let unit: String
    let color: Color
    let icon: String
    var subtitle: String? = nil
    var tooltip: String? = nil
    var history: [Double]? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline)
                if let tooltip {
                    InfoTooltip(text: tooltip, font: .caption, color: AnyShapeStyle(.secondary))
                }
                Spacer()
            }
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(value / 100, 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: value)
                VStack(spacing: 2) {
                    Text(String(format: "%.0f", value))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let history, history.count > 1 {
                Chart {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("Sample", index), y: .value("Value", point))
                    }
                }
                .foregroundStyle(color)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...100)
                .frame(height: 28)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

#Preview {
    SystemStatsView().frame(width: 800)
}
