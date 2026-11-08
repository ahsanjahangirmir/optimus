import Foundation
import ServiceManagement
import Observation

@Observable
@MainActor
final class BackgroundSamplingService {
    enum Status: Equatable {
        case off
        case enabled
        case requiresApproval
        case notFound
    }

    var status: Status = .off
    var lastError: String?

    private let service = SMAppService.agent(plistName: "com.ajm.Optimus.Sampler.plist")

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        switch service.status {
        case .notRegistered: status = .off
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .off
        }
    }

    func enable() {
        lastError = nil
        guard service.status != .enabled else { refreshStatus(); return }
        do {
            try service.register()
        } catch {
            // Some macOS versions throw when the job is already registered; treat that as success.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == 1 {
                // already registered — fall through
            } else {
                lastError = "Couldn't enable background sampling: \(error.localizedDescription)"
            }
        }
        refreshStatus()
    }

    func disable() {
        lastError = nil
        do {
            try service.unregister()
        } catch {
            lastError = "Couldn't disable background sampling: \(error.localizedDescription)"
        }
        refreshStatus()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
