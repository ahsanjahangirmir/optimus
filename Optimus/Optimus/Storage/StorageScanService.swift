import Foundation
import Observation

@Observable
@MainActor
final class StorageScanService {
    var items: [StorageItem] = []
    var progress = ScanProgress()
    var lastScanDate: Date?
    var exportMarkdown: String = ""

    func startScan() {
        Task { await runScan() }
    }

    private func runScan() async {
        progress = ScanProgress(phase: "Starting…", isRunning: true)
        items = []

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: [StorageItem] = []

        let targets: [(category: StorageCategory, paths: [String], rule: String)] = [
            (.osCache,
             ["\(home)/Library/Caches"],
             "OS-sanctioned ephemeral cache"),
            (.logFiles,
             ["\(home)/Library/Logs"],
             "System log directory"),
            (.packageManagerCache,
             ["\(home)/.npm",
              "\(home)/Library/Caches/pip",
              "\(home)/Library/Caches/Homebrew",
              "\(home)/Library/Caches/com.apple.dt.Xcode"],
             "Package manager cache directory"),
        ]

        for (idx, target) in targets.enumerated() {
            progress = ScanProgress(
                phase: "Scanning \(target.category.rawValue) (\(idx+1)/\(targets.count+2))…",
                isRunning: true
            )
            let batch = await scanDirectories(target.paths, category: target.category, rule: target.rule)
            found.append(contentsOf: batch)
            items = found
        }

        progress = ScanProgress(phase: "Scanning Orphaned App Data…", isRunning: true)
        found.append(contentsOf: await scanOrphanedAppData(home: home))
        items = found

        progress = ScanProgress(phase: "Scanning Chrome Storage…", isRunning: true)
        found.append(contentsOf: await scanChromeStorage(home: home))
        items = found

        lastScanDate = Date()
        exportMarkdown = generateMarkdown(items: found)
        DatabaseService.shared.logScan(totalBytes: found.reduce(0) { $0 + $1.sizeBytes },
                                        itemCount: found.count)
        progress = ScanProgress(phase: "Complete", isRunning: false)
    }

    // MARK: - Parallel directory scan

    private func scanDirectories(_ paths: [String], category: StorageCategory, rule: String) async -> [StorageItem] {
        await withTaskGroup(of: [StorageItem].self) { group in
            for path in paths {
                group.addTask { await self.scanTopLevel(path: path, category: category, rule: rule) }
            }
            var all: [StorageItem] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    private func scanTopLevel(path: String, category: StorageCategory, rule: String) async -> [StorageItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let children = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        var results: [StorageItem] = []
        for child in children {
            let childPath = "\(path)/\(child)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: childPath, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: childPath)
            let (size, count) = isDir.boolValue
                ? directorySize(atPath: childPath)
                : (attrs?[.size] as? Int64 ?? 0, 1)
            guard size > 0 else { continue }
            results.append(StorageItem(
                id: UUID(), path: childPath, displayName: child, category: category,
                sizeBytes: size, fileCount: count,
                lastAccessed: attrs?[.modificationDate] as? Date,
                lastModified: attrs?[.modificationDate] as? Date,
                ruleMatched: rule
            ))
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Orphaned app data

    private func scanOrphanedAppData(home: String) async -> [StorageItem] {
        let fm = FileManager.default
        let appSupportPath = "\(home)/Library/Application Support"
        guard fm.fileExists(atPath: appSupportPath),
              let entries = try? fm.contentsOfDirectory(atPath: appSupportPath) else { return [] }

        let installed = Set((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
        var results: [StorageItem] = []

        for entry in entries {
            let entryPath = "\(appSupportPath)/\(entry)"
            let appExists = installed.contains { $0.hasPrefix(entry) || entry.contains($0.dropLast(4)) }
            let (size, count) = directorySize(atPath: entryPath)
            guard size > 100_000, !appExists else { continue }
            let attrs = try? fm.attributesOfItem(atPath: entryPath)
            results.append(StorageItem(
                id: UUID(), path: entryPath, displayName: entry,
                category: .orphanedAppData, sizeBytes: size, fileCount: count,
                lastAccessed: attrs?[.modificationDate] as? Date,
                lastModified: attrs?[.modificationDate] as? Date,
                owningApp: entry, appInstalled: false,
                ruleMatched: "Owning app not found in /Applications"
            ))
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Chrome storage

    private func scanChromeStorage(home: String) async -> [StorageItem] {
        let chromeBase = "\(home)/Library/Application Support/Google/Chrome"
        let fm = FileManager.default
        guard fm.fileExists(atPath: chromeBase) else { return [] }

        var profiles: [String] = ["Default"]
        let localState = "\(chromeBase)/Local State"
        if let data = fm.contents(atPath: localState),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pInfo = json["profile"] as? [String: Any],
           let cache = pInfo["info_cache"] as? [String: Any] {
            profiles = Array(cache.keys)
        }

        var results: [StorageItem] = []
        for profile in profiles {
            let pp = "\(chromeBase)/\(profile)"
            guard fm.fileExists(atPath: pp) else { continue }

            // IndexedDB — per-origin
            let idb = "\(pp)/IndexedDB"
            if fm.fileExists(atPath: idb), let origins = try? fm.contentsOfDirectory(atPath: idb) {
                for origin in origins {
                    let op = "\(idb)/\(origin)"
                    let (sz, ct) = directorySize(atPath: op)
                    guard sz > 0 else { continue }
                    let domain = origin.replacingOccurrences(of: "https_", with: "")
                                       .replacingOccurrences(of: "http_", with: "")
                                       .components(separatedBy: "_").first ?? origin
                    results.append(StorageItem(
                        id: UUID(), path: op, displayName: domain,
                        category: .chromeIndexedDB, sizeBytes: sz, fileCount: ct,
                        lastModified: (try? fm.attributesOfItem(atPath: op))?[.modificationDate] as? Date,
                        domain: domain, chromeProfile: profile, storageType: "IndexedDB"
                    ))
                }
            }

            // Local Storage — profile total
            let ls = "\(pp)/Local Storage/leveldb"
            if fm.fileExists(atPath: ls) {
                let (sz, ct) = directorySize(atPath: ls)
                if sz > 0 {
                    results.append(StorageItem(
                        id: UUID(), path: ls, displayName: "\(profile) — Local Storage",
                        category: .chromeLocalStorage, sizeBytes: sz, fileCount: ct,
                        chromeProfile: profile, storageType: "Local Storage"
                    ))
                }
            }

            // HTTP Cache — profile total
            let cache = "\(pp)/Cache/Cache_Data"
            if fm.fileExists(atPath: cache) {
                let (sz, ct) = directorySize(atPath: cache)
                if sz > 0 {
                    results.append(StorageItem(
                        id: UUID(), path: cache, displayName: "\(profile) — HTTP Cache",
                        category: .chromeHTTPCache, sizeBytes: sz, fileCount: ct,
                        chromeProfile: profile, storageType: "HTTP Cache"
                    ))
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Helpers

    private func directorySize(atPath path: String) -> (bytes: Int64, count: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return (0, 0) }
        var total: Int64 = 0; var count = 0
        while let file = enumerator.nextObject() as? String {
            let fp = "\(path)/\(file)"
            if let a = try? fm.attributesOfItem(atPath: fp), a[.type] as? FileAttributeType != .typeDirectory {
                total += a[.size] as? Int64 ?? 0; count += 1
            }
        }
        return (total, count)
    }

    func generateMarkdown(items: [StorageItem]) -> String {
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        let ts = ISO8601DateFormatter().string(from: Date())
        var md = "# Storage Survey — \(ts)\n\n**Total reclaimable (estimate): \(formatBytes(total))**\n"
        let grouped = Dictionary(grouping: items, by: { $0.category })
        for cat in StorageCategory.allCases {
            guard let g = grouped[cat], !g.isEmpty else { continue }
            md += "- \(cat.rawValue): \(formatBytes(g.reduce(0) { $0 + $1.sizeBytes }))\n"
        }
        md += "\n"
        for cat in StorageCategory.allCases {
            guard let g = grouped[cat], !g.isEmpty else { continue }
            md += "## \(cat.rawValue)\n| Row ID | Path/Origin | Size | Last Modified | Rule Matched |\n|---|---|---|---|---|\n"
            for (i, item) in g.enumerated() {
                let mod = item.lastModified.map {
                    DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
                } ?? "—"
                md += "| \(i+1) | \(item.displayName) | \(formatBytes(item.sizeBytes)) | \(mod) | \(item.ruleMatched ?? "—") |\n"
            }
            md += "\n"
        }
        return md
    }
}
