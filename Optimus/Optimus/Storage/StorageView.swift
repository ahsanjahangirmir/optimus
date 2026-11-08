import SwiftUI

struct StorageView: View {
    @State private var service = StorageScanService()
    @State private var selectedCategory: StorageCategory? = nil
    @State private var selectedItems: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var permanentDelete = false
    @State private var showExport = false
    @State private var searchText = ""

    var displayedItems: [StorageItem] {
        var all = selectedCategory == nil ? service.items : service.items.filter { $0.category == selectedCategory }
        if !searchText.isEmpty {
            all = all.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        return all
    }

    var totalSelectedBytes: Int64 {
        displayedItems.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        HSplitView {
            sidebarPanel.frame(minWidth: 160, maxWidth: 200)
            mainPanel
        }
        .navigationTitle("Storage Survey")
        .sheet(isPresented: $showExport) {
            ExportSheet(markdown: service.exportMarkdown)
        }
        .alert(permanentDelete ? "Permanently Delete?" : "Move to Trash?",
               isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(permanentDelete ? "Delete Forever" : "Move to Trash", role: .destructive) {
                performDelete(permanent: permanentDelete)
            }
        } message: {
            Text("\(selectedItems.count) item(s), \(formatBytes(totalSelectedBytes)). Deletion will be logged.")
        }
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        List(selection: $selectedCategory) {
            Label("All Items", systemImage: "tray.2").tag(Optional<StorageCategory>.none)
            Section("Auto-Safe") {
                ForEach(StorageCategory.allCases.filter { $0.bucket == .autoSafe }) { cat in
                    categoryRow(cat)
                }
            }
            Section("Review Required") {
                ForEach(StorageCategory.allCases.filter { $0.bucket == .reviewRequired }) { cat in
                    categoryRow(cat)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func categoryRow(_ cat: StorageCategory) -> some View {
        let count = service.items.filter { $0.category == cat }.count
        return HStack {
            Text(cat.rawValue).tag(Optional(cat))
            Spacer()
            if count > 0 {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
        }
    }

    // MARK: - Main Panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if service.progress.isRunning {
                progressView
            } else if service.items.isEmpty {
                emptyState
            } else {
                itemsList
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { service.startScan() } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .disabled(service.progress.isRunning)

            if !service.items.isEmpty {
                Button { showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                if !selectedItems.isEmpty {
                    Spacer()
                    Button { permanentDelete = false; showDeleteConfirm = true } label: {
                        Label("Move to Trash (\(selectedItems.count))", systemImage: "trash")
                    }
                    Button { permanentDelete = true; showDeleteConfirm = true } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                    .foregroundStyle(.red)
                }
            }

            Spacer()
            if let date = service.lastScanDate {
                Text("Last scan: \(date, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var progressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: service.progress.percent, total: 100).frame(width: 320)
            Text(service.progress.phase).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No scan results yet").font(.title3)
            Text("Click Scan to analyze your system storage.").foregroundStyle(.secondary)
            Button("Start Scan") { service.startScan() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsList: some View {
        VStack(spacing: 0) {
            HStack {
                let total = displayedItems.reduce(0) { $0 + $1.sizeBytes }
                Text("\(displayedItems.count) items — \(formatBytes(total)) reclaimable")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if !selectedItems.isEmpty {
                    Text("\(selectedItems.count) selected — \(formatBytes(totalSelectedBytes))")
                        .font(.subheadline).fontWeight(.medium)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()

            Table(displayedItems, selection: $selectedItems) {
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).lineLimit(1)
                        Text(item.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }.width(min: 200)

                TableColumn("Category") { item in
                    BucketBadge(bucket: item.bucket, label: item.category.rawValue)
                }.width(160)

                TableColumn("Size") { item in
                    Text(formatBytes(item.sizeBytes)).fontWeight(.medium)
                }.width(90)

                TableColumn("Last Modified") { item in
                    if let d = item.lastModified { Text(d, style: .date) }
                    else { Text("—").foregroundStyle(.secondary) }
                }.width(110)

                TableColumn("Rule") { item in
                    Text(item.ruleMatched ?? "—").foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 150)
            }
        }
    }

    // MARK: - Delete

    private func performDelete(permanent: Bool) {
        let fm = FileManager.default
        let targets = displayedItems.filter { selectedItems.contains($0.id) }
        for item in targets {
            let url = URL(fileURLWithPath: item.path)
            DatabaseService.shared.logDeletion(path: item.path, sizeBytes: item.sizeBytes,
                                                action: permanent ? "permanent" : "trash")
            if permanent { try? fm.removeItem(at: url) }
            else         { try? fm.trashItem(at: url, resultingItemURL: nil) }
        }
        selectedItems = []
        service.startScan()
    }
}

struct BucketBadge: View {
    let bucket: StorageBucket
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(bucket == .autoSafe ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .foregroundStyle(bucket == .autoSafe ? .green : .orange)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
    }
}

struct ExportSheet: View {
    let markdown: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scan Report").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            ScrollView {
                Text(markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 700, height: 520)
    }
}

#Preview {
    StorageView().frame(width: 900)
}
