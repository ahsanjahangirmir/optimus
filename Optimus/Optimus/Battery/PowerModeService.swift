import Foundation
import Observation

enum EnergyMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case lowPower = "Low Power"
    case highPower = "High Power"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .automatic: return "gauge.medium"
        case .lowPower: return "leaf.fill"
        case .highPower: return "bolt.fill"
        }
    }

    fileprivate var pmsetValue: Int {
        switch self {
        case .automatic: return 0
        case .lowPower: return 1
        case .highPower: return 2
        }
    }
}

/// Reads and sets macOS's Energy Mode (the Automatic / Low Power / High Power picker
/// in System Settings > Battery) via `pmset`.
///
/// macOS Ventura and later control all three states with a single unified key,
/// `powermode` (0 = Automatic, 1 = Low Power, 2 = High Power) — NOT separate
/// `lowpowermode`/`highpowermode` booleans. Changing it is a system-wide setting
/// and requires root, so `setMode` shells out through `osascript ... with
/// administrator privileges`, which triggers the standard macOS password/Touch ID
/// prompt. macOS caches that authorization for a few minutes, so rapid successive
/// toggles usually won't re-prompt — but the first one in a session will.
///
/// High Power Mode is only offered on Macs with a Pro/Max/Ultra chip, so
/// `refresh()` checks the chip name and exposes that via `supportsHighPower`,
/// letting the UI hide the option where Apple doesn't offer it either.
///
/// Note: this app applies one mode across both power sources (`pmset -a`).
/// System Settings itself lets "On Battery" and "On Power Adapter" differ —
/// worth knowing if the mode you set here doesn't match what you see in the
/// menu bar for the *other* power source.
@Observable
@MainActor
final class PowerModeService {
    var currentMode: EnergyMode = .automatic
    var supportsHighPower: Bool = true
    var isApplying: Bool = false
    var lastError: String?

    func refresh() async {
        if let pmsetOutput = try? await Shell.run("/usr/bin/pmset", ["-g", "custom"]) {
            switch Self.powerModeValue(in: pmsetOutput) {
            case 2: currentMode = .highPower
            case 1: currentMode = .lowPower
            default: currentMode = .automatic
            }
        }
        supportsHighPower = await Self.chipSupportsHighPower()
    }

    func setMode(_ mode: EnergyMode) {
        guard mode != currentMode, !isApplying else { return }
        isApplying = true
        lastError = nil

        Task {
            defer { isApplying = false }
            do {
                try await Shell.run("/usr/bin/osascript", [
                    "-e", Self.privilegedScript(value: mode.pmsetValue)
                ])
                currentMode = mode
            } catch {
                lastError = "Couldn't change energy mode: \(error.localizedDescription)"
                await refresh() // resync with actual system state after a failed change
            }
        }
    }

    private static func privilegedScript(value: Int) -> String {
        "do shell script \"/usr/bin/pmset -a powermode \(value)\" with administrator privileges"
    }

    private static func powerModeValue(in pmsetCustomOutput: String) -> Int {
        for line in pmsetCustomOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("powermode") {
                let digits = trimmed
                    .replacingOccurrences(of: "powermode", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return Int(digits) ?? 0
            }
        }
        return 0
    }

    /// Apple offers High Power Mode only on Pro/Max/Ultra-chip Macs. The `powermode`
    /// key itself doesn't reveal this (it's present regardless), so this checks the
    /// chip name from `system_profiler SPHardwareDataType` instead. Fails open (shows
    /// the option) if the chip can't be read, rather than risk hiding a real feature.
    private static func chipSupportsHighPower() async -> Bool {
        guard let output = try? await Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType"]) else {
            return true
        }
        guard let chipLine = output.split(separator: "\n")
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Chip:") })
        else {
            return true
        }
        return chipLine.contains("Pro") || chipLine.contains("Max") || chipLine.contains("Ultra")
    }
}
