import Foundation
import ServiceManagement
import Observation

/// Installs and talks to the root-privileged `OptimusFanHelper` daemon (see
/// OptimusFanHelper/main.swift), which is the only part of the app allowed to write fan
/// speed targets to the SMC. Mirrors `BackgroundSamplingService`'s install/status pattern,
/// swapping `SMAppService.agent` for its root-privileged sibling `SMAppService.daemon`.
@Observable
@MainActor
final class FanHelperService {
    enum Status: Equatable {
        case off
        case enabled
        case requiresApproval
        case notFound
    }

    var status: Status = .off
    var lastError: String?

    private let service = SMAppService.daemon(plistName: "com.ajm.Optimus.FanHelper.plist")
    private var connection: NSXPCConnection?

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

    /// Registers the helper if it isn't already. Called lazily on first user interaction
    /// with a fan control, not eagerly at launch, so root access stays scoped to the
    /// moment the user actually asks to write a fan speed.
    func install() {
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
                lastError = "Couldn't install fan control helper: \(error.localizedDescription)"
            }
        }
        refreshStatus()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func version() async -> String? {
        await withCheckedContinuation { cont in
            guard let proxy = proxy(errorHandler: { _ in cont.resume(returning: nil) }) else {
                cont.resume(returning: nil)
                return
            }
            proxy.version { version in cont.resume(returning: version) }
        }
    }

    func setFanTarget(id: Int, rpm: Double) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            guard let proxy = proxy(errorHandler: { error in cont.resume(returning: .failure(error)) }) else {
                cont.resume(returning: .failure(FanHelperError.notConnected))
                return
            }
            proxy.setFanTarget(id: id, rpm: rpm) { success, message in
                if success {
                    cont.resume(returning: .success(()))
                } else {
                    cont.resume(returning: .failure(FanHelperError.rejected(message ?? "Unknown error")))
                }
            }
        }
    }

    func setFanAuto(id: Int) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            guard let proxy = proxy(errorHandler: { error in cont.resume(returning: .failure(error)) }) else {
                cont.resume(returning: .failure(FanHelperError.notConnected))
                return
            }
            proxy.setFanAuto(id: id) { success, message in
                if success {
                    cont.resume(returning: .success(()))
                } else {
                    cont.resume(returning: .failure(FanHelperError.rejected(message ?? "Unknown error")))
                }
            }
        }
    }

    private func proxy(errorHandler: @escaping (Error) -> Void) -> FanHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: kFanHelperMachServiceName, options: [])
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? FanHelperProtocol
    }
}

enum FanHelperError: LocalizedError {
    case notConnected
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the fan control helper."
        case .rejected(let message): return message
        }
    }
}
