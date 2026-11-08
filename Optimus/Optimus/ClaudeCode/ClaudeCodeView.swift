import SwiftUI

struct ClaudeCodeView: View {
    @State private var service = ClaudeCodeService()
    @State private var selectedEntry: ClaudeEntry?
    @State private var showPurgeSheet = false
    @State private var purgeTarget: ClaudeSubEntry?
    @State private var confirmManualClear: ClaudeFolder?
    @State private var cleanupDays: String = ""

    var body: some View {
        HSplitView {
            folderList.frame(minWidth: 280, maxWidth: 320)
            detailPanel
        }
        .navigationTitle("Claude Code")
        .onAppear { service.start(); cleanupDays = "\(service.cleanupPeriodDays)" }
        .onDisappear { service.stop() }
        .sheet(isPresented: $showPurgeSheet) { purgeSheet }
        .alert("Clear \(confirmManualClear?.rawValue ?? "")?",
               isPresented: .init(get: { confirmManualClear != nil }, set: { if !$0 { confirmManualClear = nil } })) {
            Button("Cancel", role: .cancel) { confirmManualClear = nil }
            Button("Clear", role: .destructive) {
                if let f = confirmManualClear { service.manualClear(folder: f) }
                confirmManualClear = nil
            }
        } message: {
            Text("This folder is not covered by `claude project purge`. Clear it manually?")
        }
    }

    // MARK: - Folder list

    private var folderList: some View {
        List(service.entries, selection: $selectedEntry) { entry in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.folder.rawValue).font(.system(.body, design: .monospaced))
                        kindBadge(entry.folder.kind)
                    }
                    Text(entry.folder.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(entry.sizeBytes)).fontWeight(.medium)
                    Text("\(entry.fileCount) files").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .tag(entry)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func kindBadge(_ kind: ClaudeFolder.Kind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .projectScoped:  return ("purge",     .blue)
            case .ephemeralCache: return ("cache",     .green)
            case .manualOnly:     return ("manual",    .orange)
            case .neverDelete:    return ("protected", .red)
            case .lowConfidence:  return ("?",         .secondary)
            }
        }()
        Text(label).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12)).foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard
                if let entry = selectedEntry {
                    entryDetail(entry)
                } else {
                    Text("Select a folder to see details and cleanup options.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .padding(20)
        }
    }

    private var settingsCard: some View {
        InfoCard(title: "Retention Settings") {
            HStack {
                Text("Auto-cleanup after").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    TextField("30", text: $cleanupDays)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("days")
                    Button("Save") {
                        if let d = Int(cleanupDays) { service.saveCleanupPeriod(d) }
                    }.buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Text("Controls `cleanupPeriodDays` in ~/.claude/settings.json.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func entryDetail(_ entry: ClaudeEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("~/.claude/\(entry.folder.rawValue)").font(.title3.monospaced())
                    Text(entry.folder.description).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(formatBytes(entry.sizeBytes)).font(.title2).fontWeight(.semibold)
                    Text("\(entry.fileCount) files").foregroundStyle(.secondary).font(.caption)
                }
            }

            actionButtons(entry)

            if !entry.subEntries.isEmpty {
                InfoCard(title: "Sub-entries") {
                    ForEach(entry.subEntries) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sub.name).lineLimit(1)
                                Text(sub.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Text(formatBytes(sub.sizeBytes)).fontWeight(.medium)
                            if entry.folder.kind == .projectScoped {
                                Button("Purge…") {
                                    purgeTarget = sub; showPurgeSheet = true
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ entry: ClaudeEntry) -> some View {
        switch entry.folder.kind {
        case .projectScoped:
            Button("Dry-run Purge All") {
                purgeTarget = ClaudeSubEntry(
                    name: entry.folder.rawValue,
                    path: "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/\(entry.folder.rawValue)",
                    sizeBytes: entry.sizeBytes, fileCount: entry.fileCount)
                showPurgeSheet = true
            }
            .buttonStyle(.bordered)
        case .ephemeralCache:
            Button("Clear Cache", role: .destructive) { confirmManualClear = entry.folder }
                .buttonStyle(.bordered)
        case .manualOnly:
            Button("Clear Manually…", role: .destructive) { confirmManualClear = entry.folder }
                .buttonStyle(.bordered)
        case .neverDelete:
            Label("Protected — do not delete", systemImage: "lock")
                .foregroundStyle(.secondary).font(.caption)
        case .lowConfidence:
            Label("Purpose unconfirmed — confirm before clearing", systemImage: "questionmark.circle")
                .foregroundStyle(.orange).font(.caption)
        }
    }

    // MARK: - Purge Sheet

    private var purgeSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Purge").font(.headline)
                    if let t = purgeTarget { Text(t.path).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Close") { showPurgeSheet = false }
            }
            .padding()
            Divider()

            if service.isRunningPurge {
                ProgressView("Running purge…").padding(40)
            } else if service.purgeOutput.isEmpty {
                VStack(spacing: 16) {
                    Text("This will shell out to `claude project purge` on the selected path.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Dry Run (Preview)") {
                            if let t = purgeTarget {
                                Task { await service.dryRunPurge(projectPath: t.path) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Purge for Real", role: .destructive) {
                            if let t = purgeTarget {
                                Task { await service.confirmPurge(projectPath: t.path) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(service.purgeOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                HStack {
                    Spacer()
                    Button("Purge for Real", role: .destructive) {
                        if let t = purgeTarget {
                            Task { await service.confirmPurge(projectPath: t.path) }
                        }
                    }
                    .buttonStyle(.bordered).disabled(service.isRunningPurge)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 420)
    }
}

#Preview {
    ClaudeCodeView().frame(width: 900)
}
