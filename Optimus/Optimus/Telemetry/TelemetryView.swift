import SwiftUI

private enum DeleteRange: String, CaseIterable, Identifiable {
    case sevenDays = "Older than 7 days"
    case thirtyDays = "Older than 30 days"
    case ninetyDays = "Older than 90 days"
    case all = "All data"

    var id: String { rawValue }

    var cutoffDate: Date? {
        let cal = Calendar.current
        switch self {
        case .sevenDays: return cal.date(byAdding: .day, value: -7, to: Date())
        case .thirtyDays: return cal.date(byAdding: .day, value: -30, to: Date())
        case .ninetyDays: return cal.date(byAdding: .day, value: -90, to: Date())
        case .all: return nil
        }
    }
}

struct TelemetryView: View {
    @State private var background = BackgroundSamplingService()
    @State private var data = TelemetryDataService()
    @State private var deleteRange: DeleteRange = .thirtyDays
    @State private var pendingDelete: DeleteRange?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                collectionSection
                storageSection
                deletionSection
            }
            .padding(24)
        }
        .navigationTitle("Telemetry")
        .onAppear { background.refreshStatus() }
        .task { await data.refresh() }
        .alert(
            pendingDelete.map { "Delete \($0.rawValue.lowercased())?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let range = pendingDelete {
                    Task {
                        await data.deleteData(before: range.cutoffDate)
                        pendingDelete = nil
                    }
                }
            }
        } message: {
            Text("This permanently removes battery, system, and power-event history in that range. This cannot be undone.")
        }
    }

    private var collectionSection: some View {
        InfoCard(title: "Background Collection",
                 tooltip: "When enabled, a lightweight helper process records CPU, RAM, disk, and battery metrics once a minute, even while Optimus itself is closed, so history keeps building in the background. Nothing leaves this Mac — it's all stored locally.") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { background.status == .enabled },
                    set: { newValue in
                        if newValue { background.enable() } else { background.disable() }
                    }
                )) {
                    Text("Collect data in the background")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if background.status == .requiresApproval {
                    Button("Open System Settings") { background.openSystemSettings() }
                        .padding(.horizontal, 16)
                }

                if let error = background.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var storageSection: some View {
        InfoCard(title: "Stored Data",
                 tooltip: "How much telemetry history is currently saved on this Mac, per table.") {
            InfoRow("Battery samples", value: summaryText(data.batterySummary))
            InfoRow("System samples", value: summaryText(data.systemSummary))
            InfoRow("Power events", value: summaryText(data.powerEventsSummary))
        }
    }

    private var deletionSection: some View {
        InfoCard(title: "Delete Data",
                 tooltip: "Manually remove stored history. Deletion is permanent and only ever happens when you ask for it — nothing is pruned automatically.") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Range", selection: $deleteRange) {
                    ForEach(DeleteRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Button("Delete", role: .destructive) {
                    pendingDelete = deleteRange
                }
                .disabled(data.isBusy)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }

    private var statusLabel: String {
        switch background.status {
        case .off: return "Off — no background sampling is running."
        case .enabled: return "On — sampling every 60 seconds."
        case .requiresApproval: return "Needs approval in System Settings → Login Items."
        case .notFound: return "Not available (helper not found in this build)."
        }
    }

    private func summaryText(_ summary: TableStorageSummary) -> String {
        guard summary.rowCount > 0, let oldest = summary.oldest, let newest = summary.newest else {
            return "No data yet"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(summary.rowCount) rows · \(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
    }
}

#Preview {
    TelemetryView().frame(width: 700)
}
