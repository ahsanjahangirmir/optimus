import Foundation
import Observation

enum ClaudeFolder: String, CaseIterable, Identifiable {
    case projects = "projects"
    case tasks = "tasks"
    case debug = "debug"
    case fileHistory = "file-history"
    case historyJsonl = "history.jsonl"
    case cache = "cache"
    case pasteCache = "paste-cache"
    case telemetry = "telemetry"
    case shellSnapshots = "shell-snapshots"
    case backups = "backups"
    case sessions = "sessions"
    case sessionEnv = "session-env"
    case ide = "ide"
    case chrome = "chrome"
    case skills = "skills"

    var id: String { rawValue }

    enum Kind { case projectScoped, ephemeralCache, manualOnly, neverDelete, lowConfidence }

    var kind: Kind {
        switch self {
        case .projects, .tasks, .debug, .fileHistory, .historyJsonl: return .projectScoped
        case .cache, .pasteCache, .telemetry: return .ephemeralCache
        case .shellSnapshots, .backups: return .manualOnly
        case .sessions, .sessionEnv, .ide, .chrome, .skills: return .lowConfidence
        }
    }

    var description: String {
        switch self {
        case .projects:       return "Per-project data and transcripts"
        case .tasks:          return "Task lists and session state"
        case .debug:          return "Debug output"
        case .fileHistory:    return "File edit history per session"
        case .historyJsonl:   return "Conversation history log"
        case .cache:          return "Ephemeral cache — safe to clear"
        case .pasteCache:     return "Paste buffer cache — safe to clear"
        case .telemetry:      return "Telemetry data — safe to clear"
        case .shellSnapshots: return "Shell env snapshots — manual clear only"
        case .backups:        return "File backups — manual clear only"
        case .sessions:       return "Possibly session state — purpose unconfirmed"
        case .sessionEnv:     return "Possibly session env — purpose unconfirmed"
        case .ide:            return "IDE integration state — purpose unconfirmed"
        case .chrome:         return "Chrome integration state — purpose unconfirmed"
        case .skills:         return "Installed skills — purpose unconfirmed"
        }
    }
}

struct ClaudeEntry: Identifiable, Hashable {
    let id = UUID()
    var folder: ClaudeFolder
    var sizeBytes: Int64
    var fileCount: Int
    var subEntries: [ClaudeSubEntry]

    static func == (lhs: ClaudeEntry, rhs: ClaudeEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ClaudeSubEntry: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var sizeBytes: Int64
    var fileCount: Int
}

@Observable
@MainActor
final class ClaudeCodeService {
    var entries: [ClaudeEntry] = []
    var cleanupPeriodDays: Int = 30
    var purgeOutput: String = ""
    var isRunningPurge = false

    private var timer: Timer?
    private let claudeDir: String

    init() {
        claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        loadSettings()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let fm = FileManager.default
        var result: [ClaudeEntry] = []
        for folder in ClaudeFolder.allCases {
            let fullPath = "\(claudeDir)/\(folder.rawValue)"
            guard fm.fileExists(atPath: fullPath) else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            if isDir.boolValue {
                let (sz, ct, subs) = dirSize(atPath: fullPath)
                result.append(ClaudeEntry(folder: folder, sizeBytes: sz, fileCount: ct, subEntries: subs))
            } else {
                let sz = (try? fm.attributesOfItem(atPath: fullPath))?[.size] as? Int64 ?? 0
                result.append(ClaudeEntry(folder: folder, sizeBytes: sz, fileCount: 1, subEntries: []))
            }
        }
        entries = result
    }

    private func dirSize(atPath path: String) -> (bytes: Int64, count: Int, subs: [ClaudeSubEntry]) {
        let fm = FileManager.default
        var total: Int64 = 0; var count = 0; var subs: [ClaudeSubEntry] = []
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return (0, 0, []) }
        for child in children {
            let cp = "\(path)/\(child)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: cp, isDirectory: &isDir)
            if isDir.boolValue {
                var subSz: Int64 = 0; var subCt = 0
                if let enumerator = fm.enumerator(atPath: cp) {
                    while let f = enumerator.nextObject() as? String {
                        let fp = "\(cp)/\(f)"
                        if let a = try? fm.attributesOfItem(atPath: fp), a[.type] as? FileAttributeType != .typeDirectory {
                            subSz += a[.size] as? Int64 ?? 0; subCt += 1
                        }
                    }
                }
                total += subSz; count += subCt
                subs.append(ClaudeSubEntry(name: child, path: cp, sizeBytes: subSz, fileCount: subCt))
            } else {
                let sz = (try? fm.attributesOfItem(atPath: cp))?[.size] as? Int64 ?? 0
                total += sz; count += 1
            }
        }
        subs.sort { $0.sizeBytes > $1.sizeBytes }
        return (total, count, subs)
    }

    func loadSettings() {
        let path = "\(claudeDir)/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = json["cleanupPeriodDays"] as? Int else { return }
        cleanupPeriodDays = days
    }

    func saveCleanupPeriod(_ days: Int) {
        let path = "\(claudeDir)/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["cleanupPeriodDays"] = days
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? newData.write(to: URL(fileURLWithPath: path))
            cleanupPeriodDays = days
        }
    }

    func dryRunPurge(projectPath: String) async { await runPurge(projectPath: projectPath, dryRun: true) }
    func confirmPurge(projectPath: String)  async { await runPurge(projectPath: projectPath, dryRun: false) }

    private func runPurge(projectPath: String, dryRun: Bool) async {
        isRunningPurge = true; purgeOutput = ""
        var args = ["project", "purge", projectPath]
        if dryRun { args.append("--dry-run") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + args
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run(); process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            purgeOutput = String(data: data, encoding: .utf8) ?? "No output"
        } catch {
            purgeOutput = "Failed to run claude: \(error.localizedDescription)"
        }
        isRunningPurge = false
    }

    func manualClear(folder: ClaudeFolder) {
        try? FileManager.default.removeItem(atPath: "\(claudeDir)/\(folder.rawValue)")
        refresh()
    }
}
