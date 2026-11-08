import Foundation

/// Read-only energy-mode lookup for the background helper's `battery_samples.energy_mode`
/// column. Deliberately separate from `Battery/PowerModeService.swift` (GUI-only, owns
/// setting the mode too) rather than shared, to avoid touching that working file — the
/// `pmset -g custom` parsing below is intentionally the same handful of lines duplicated.
enum PowerModeProbe {
    static func readCurrentModeName() async -> String {
        guard let output = try? await Shell.run("/usr/bin/pmset", ["-g", "custom"]) else { return "Automatic" }
        switch value(in: output) {
        case 2: return "High Power"
        case 1: return "Low Power"
        default: return "Automatic"
        }
    }

    private static func value(in pmsetCustomOutput: String) -> Int {
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
}
