import Foundation

enum StorageBucket: String, CaseIterable {
    case autoSafe = "Auto-Safe"
    case reviewRequired = "Review Required"
}

enum StorageCategory: String, CaseIterable, Identifiable {
    case osCache = "OS Cache"
    case logFiles = "Log Files"
    case orphanedAppData = "Orphaned App Data"
    case packageManagerCache = "Package Manager Cache"
    case chromeIndexedDB = "Chrome IndexedDB"
    case chromeLocalStorage = "Chrome Local Storage"
    case chromeHTTPCache = "Chrome HTTP Cache"

    var id: String { rawValue }
    var bucket: StorageBucket {
        switch self {
        case .chromeIndexedDB, .chromeLocalStorage, .chromeHTTPCache: return .reviewRequired
        default: return .autoSafe
        }
    }
}

struct StorageItem: Identifiable {
    let id: UUID
    var path: String
    var displayName: String
    var category: StorageCategory
    var sizeBytes: Int64
    var fileCount: Int
    var lastAccessed: Date?
    var lastModified: Date?
    var owningApp: String?
    var appInstalled: Bool?
    var ruleMatched: String?
    var bucket: StorageBucket { category.bucket }

    // Chrome-specific
    var domain: String?
    var chromeProfile: String?
    var storageType: String?
    var isPersisted: Bool?
    var isPWA: Bool?
}

struct ScanProgress {
    var phase: String = ""
    var currentItem: String = ""
    var completed: Int = 0
    var total: Int = 0
    var isRunning: Bool = false
    var percent: Double { total > 0 ? Double(completed) / Double(total) * 100 : 0 }
}
