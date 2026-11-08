import Foundation
import IOKit

/// Root-privileged daemon whose only job is writing fan speed targets to the SMC.
/// Registered via `SMAppService.daemon` (see `FanHelperService` in the main app) rather
/// than legacy `SMJobBless` — see spec.md §6 and the fan-control fix plan for rationale.
/// Everything else the app does, including SMC *reads*, runs unprivileged in-process;
/// this binary exists solely to scope root access to the one write operation.
final class FanHelperImpl: NSObject, FanHelperProtocol {
    /// Fan mode key name varies by machine/firmware ("F%Md" vs "F%md") — probed once
    /// per fan index and cached for this daemon's lifetime.
    private var fanModeKeyCache: [Int: String] = [:]

    func version(withReply reply: @escaping (String) -> Void) {
        reply("1.0")
    }

    func setFanTarget(id: Int, rpm: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        let opened = SMCBridge.openSMC()
        guard opened.serviceFound, opened.openError == kIOReturnSuccess else {
            reply(false, "AppleSMC unavailable")
            return
        }
        defer { SMCBridge.closeSMC(opened.conn) }

        guard enableManualMode(conn: opened.conn, fan: id) else {
            reply(false, "Could not enable manual mode for fan \(id)")
            return
        }

        let result = writeWithRetry(conn: opened.conn, key: "F\(id)Tg", value: rpm)
        if result.ioReturn == kIOReturnSuccess && result.smcResult == 0 {
            reply(true, nil)
        } else {
            reply(false, "SMC rejected fan target write (result \(result.smcResult))")
        }
    }

    func setFanAuto(id: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        let opened = SMCBridge.openSMC()
        guard opened.serviceFound, opened.openError == kIOReturnSuccess else {
            reply(false, "AppleSMC unavailable")
            return
        }
        defer { SMCBridge.closeSMC(opened.conn) }

        guard let modeKey = fanModeKey(conn: opened.conn, fan: id) else {
            reply(false, "Could not determine fan mode key for fan \(id)")
            return
        }

        let result = writeWithRetry(conn: opened.conn, key: modeKey, value: 0)
        if result.ioReturn == kIOReturnSuccess && result.smcResult == 0 {
            reply(true, nil)
        } else {
            reply(false, "SMC rejected fan auto-mode write (result \(result.smcResult))")
        }
    }

    // MARK: - Helpers

    private func fanModeKey(conn: io_connect_t, fan id: Int) -> String? {
        if let cached = fanModeKeyCache[id] { return cached }
        // The AppleSMC user client can transiently reject a read under contention (e.g.
        // the main app's SMCService polling at the same moment) — retry briefly before
        // concluding the key genuinely doesn't exist on this machine.
        for attempt in 0..<5 {
            for candidate in ["F\(id)Md", "F\(id)md"] {
                let probe = SMCBridge.readKey(conn, candidate)
                if probe.ioReturn == kIOReturnSuccess && probe.smcResult == 0 {
                    fanModeKeyCache[id] = candidate
                    return candidate
                }
            }
            if attempt < 4 { usleep(50_000) }
        }
        return nil
    }

    private func enableManualMode(conn: io_connect_t, fan id: Int) -> Bool {
        guard let modeKey = fanModeKey(conn: conn, fan: id) else { return false }

        var result = writeWithRetry(conn: conn, key: modeKey, value: 1)
        if result.ioReturn == kIOReturnSuccess && result.smcResult == 0 { return true }

        // Apple-Silicon-specific unlock: some machines reject the mode write until
        // "Ftst" is set first (thermalmonitord needs a moment to yield control).
        // Reportedly unnecessary on M5+ — check the key exists before relying on it.
        let ftstProbe = SMCBridge.readKey(conn, "Ftst")
        guard ftstProbe.ioReturn == kIOReturnSuccess else { return false }
        _ = SMCBridge.writeKey(conn, "Ftst", value: 1)
        Thread.sleep(forTimeInterval: 3)
        result = writeWithRetry(conn: conn, key: modeKey, value: 1)
        return result.ioReturn == kIOReturnSuccess && result.smcResult == 0
    }

    private func writeWithRetry(conn: io_connect_t, key: String, value: Double,
                                  attempts: Int = 10, delayMs: UInt32 = 50) -> (ioReturn: kern_return_t, smcResult: UInt8) {
        var last: (ioReturn: kern_return_t, smcResult: UInt8) = (kern_return_t(-1), 0xFF)
        for _ in 0..<attempts {
            last = SMCBridge.writeKey(conn, key, value: value)
            if last.ioReturn == kIOReturnSuccess && last.smcResult == 0 { return last }
            usleep(delayMs * 1000)
        }
        return last
    }
}

final class FanHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard CodesignCheck.isValidPeer(pid: connection.processIdentifier, expectedIdentifier: kOptimusBundleIdentifier) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = FanHelperImpl()
        connection.resume()
        return true
    }
}

let delegate = FanHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: kFanHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
