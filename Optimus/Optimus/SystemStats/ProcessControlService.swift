import Foundation
import Observation
import Darwin

/// Process names that get a stronger confirmation warning — force-quitting these can
/// log you out or crash the Mac outright (e.g. WindowServer), with no OS-level warning.
private let criticalProcessNames: Set<String> = [
    "kernel_task", "launchd", "WindowServer", "loginwindow",
    "coreaudiod", "logd", "mds", "SystemUIServer"
]

func isCriticalProcess(pid: Int32, name: String) -> Bool {
    pid <= 1 || criticalProcessNames.contains(name)
}

/// Terminates a process, mirroring `PowerModeService`'s privileged-action shape
/// (`isApplying` + `lastError`, `Task { defer { isApplying = false }; ... }`).
@Observable
@MainActor
final class ProcessControlService {
    var isApplying = false
    var lastError: String?
    private(set) var targetName: String?

    func terminate(pid: pid_t, name: String, force: Bool, onSuccess: @escaping () -> Void) {
        guard !isApplying, pid > 1, pid != getpid() else { return }
        isApplying = true
        lastError = nil
        targetName = name

        Task {
            defer { isApplying = false; targetName = nil }

            let signal = force ? SIGKILL : SIGTERM
            if kill(pid, signal) == 0 {
                onSuccess()
                return
            }

            let err = errno
            if err == ESRCH {
                // Already gone — that's the outcome the user wanted.
                onSuccess()
                return
            }
            guard err == EPERM else {
                lastError = "Couldn't quit \(name): \(String(cString: strerror(err)))"
                return
            }

            // Not owned by us — escalate via the same osascript-administrator-privileges
            // mechanism PowerModeService uses for pmset. `pid` is a kernel-supplied Int32,
            // not user text, so string interpolation here carries no injection risk.
            do {
                let sig = force ? "KILL" : "TERM"
                try await Shell.run("/usr/bin/osascript", [
                    "-e", "do shell script \"/bin/kill -\(sig) \(pid)\" with administrator privileges"
                ])
                onSuccess()
            } catch {
                let message = error.localizedDescription
                if message.contains("User canceled") || message.contains("User cancelled") {
                    // Deliberate choice, not a failure — leave lastError nil.
                    return
                }
                lastError = "Couldn't quit \(name): \(message)"
            }
        }
    }
}
