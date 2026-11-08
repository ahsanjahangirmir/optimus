import Foundation
import AppKit

// Per-process audio settings that survive app relaunch. PID and AudioObjectID
// are not stable across relaunches, so settings are keyed by bundle ID
// (falling back to executable name for non-bundled processes like CLI tools
// or daemons — a known limitation: two different unrelated same-named
// binaries would share settings, acceptable on a personal single-user
// machine).
struct ProcessAudioSettings: Codable, Equatable {
    var volume: Float = 1.0
    var isMuted: Bool = false
    var outputDeviceUID: String?
}

@MainActor
final class SoundPreferences {
    static let boostCeiling: Float = 2.0

    private static let keyPrefix = "com.ajm.Optimus.sound.process."
    private static let airPodsKey = "com.ajm.Optimus.sound.airPodsAutoToggleEnabled"
    private static let savedInputDeviceUIDKey = "com.ajm.Optimus.sound.savedInputDeviceUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func stableKey(pid: pid_t, fallbackExecutableName: String) -> String {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            return bundleID
        }
        return "exe:\(fallbackExecutableName)"
    }

    func settings(for key: String) -> ProcessAudioSettings {
        guard let data = defaults.data(forKey: Self.keyPrefix + key),
              let decoded = try? JSONDecoder().decode(ProcessAudioSettings.self, from: data) else {
            return ProcessAudioSettings()
        }
        return decoded
    }

    func setSettings(_ settings: ProcessAudioSettings, for key: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.keyPrefix + key)
    }

    var airPodsAutoToggleEnabled: Bool {
        get { defaults.bool(forKey: Self.airPodsKey) }
        set { defaults.set(newValue, forKey: Self.airPodsKey) }
    }

    // Set the instant the AirPods toggle swaps input away from Bluetooth, and
    // cleared the instant it's restored. If Optimus quits (or crashes) while
    // this is non-nil, the swap was never undone — the next launch uses it to
    // self-heal instead of leaving the system stranded on the built-in mic
    // with no memory of which Bluetooth device to restore.
    var savedInputDeviceUID: String? {
        get { defaults.string(forKey: Self.savedInputDeviceUIDKey) }
        set { defaults.set(newValue, forKey: Self.savedInputDeviceUIDKey) }
    }
}
