import Foundation
import Observation
import CoreAudio
import AVFoundation
import AppKit
import Darwin

private let procPathInfoMax = 4096

struct AudioProcess: Identifiable {
    let id: AudioObjectID   // HAL process object ID
    var name: String
    var pid: pid_t
    var isRunning: Bool
    var isRunningInput: Bool
    var isRunningOutput: Bool
    var icon: NSImage?
    var volume: Float = 1.0
    var isMuted: Bool = false
    var outputDeviceUID: String?   // nil = follow system default output
}

// MARK: - SoundService
@Observable
@MainActor
final class SoundService {
    var processes: [AudioProcess] = []
    var defaultOutputDeviceSummary = AudioDeviceSummary()
    var defaultInputDeviceSummary = AudioDeviceSummary()
    var availableOutputDevices: [AudioOutputDevice] = []
    var microphonePermissionDenied: Bool = false

    var airPodsAutoToggleEnabled: Bool {
        didSet {
            preferences.airPodsAutoToggleEnabled = airPodsAutoToggleEnabled
            if !airPodsAutoToggleEnabled && autoToggleActive { restoreOriginalInput() }
        }
    }
    var autoToggleActive: Bool = false

    private let preferences = SoundPreferences()
    private var timer: Timer?
    // AnyObject storage keeps ProcessTapContext's macOS 14.2 availability
    // annotation from leaking onto this stored property's declaration.
    private var tapContexts: [AudioObjectID: AnyObject] = [:]
    private var processKeys: [AudioObjectID: String] = [:]
    private var pinnedOutputRoutes: [AudioObjectID: String] = [:]   // presence = pinned; absence = follow default
    private var lastKnownDefaultOutputUID: String?
    private var savedInputDeviceID: AudioDeviceID?
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        airPodsAutoToggleEnabled = preferences.airPodsAutoToggleEnabled

        // Self-heal: if Optimus quit (or crashed) last time while the AirPods
        // toggle had swapped input away from Bluetooth, that swap was never
        // undone — the OS is still stranded on the built-in mic with nothing
        // left in memory to know what to restore. Recover it now.
        if let staleUID = preferences.savedInputDeviceUID {
            if let deviceID = deviceID(forUID: staleUID) {
                setDefaultInputDevice(deviceID)
            }
            preferences.savedInputDeviceUID = nil
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let outputID = currentDefaultOutputDeviceID()
        let inputID = currentDefaultInputDeviceID()
        defaultOutputDeviceSummary = deviceSummary(for: outputID)
        defaultInputDeviceSummary = deviceSummary(for: inputID)
        availableOutputDevices = loadAvailableOutputDevices()

        let defaultOutputUID = deviceUID(for: outputID)
        if defaultOutputUID != lastKnownDefaultOutputUID {
            for (objID, ctx) in tapContexts {
                guard pinnedOutputRoutes[objID] == nil, let ctx = ctx as? ProcessTapContext,
                      let newUID = defaultOutputUID else { continue }
                ctx.retarget(toOutputDeviceUID: newUID)
            }
            lastKnownDefaultOutputUID = defaultOutputUID
        }

        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionDenied = (permissionStatus == .denied || permissionStatus == .restricted)

        let runningIDs = Set(enumerateRunningProcessIDs())

        // `processKeys` (not `tapContexts`) is the "have we seen this process
        // this session" tracker — most processes never get a tap at all now
        // (see below), so `tapContexts.keys` alone can't tell new from known.
        let existing = Set(processKeys.keys)
        for stale in existing.subtracting(runningIDs) {
            tapContexts.removeValue(forKey: stale)
            processKeys.removeValue(forKey: stale)
            pinnedOutputRoutes.removeValue(forKey: stale)
        }
        // Just discover and remember new processes — never tap anything here.
        // Tapping (even a no-op unmuted tap) turned out to make macOS apply
        // its own audio-ducking policy to that process for as long as the tap
        // exists, which audibly quiets things like live calls. So a tap is
        // only ever created in response to the user explicitly touching a
        // volume/mute/output control for that specific process this session
        // (see ensureActiveContext) — never automatically, and never merely
        // because a previous session had saved a non-default setting for it.
        for new in runningIDs.subtracting(existing) {
            let pid = getPID(new)
            guard pid > 0 else { continue }
            processKeys[new] = preferences.stableKey(pid: pid, fallbackExecutableName: processName(pid))
        }

        processes = runningIDs.sorted().compactMap { objID -> AudioProcess? in
            let pid = getPID(objID)
            guard pid > 0 else { return nil }
            let runningInput = getUInt32Property(objID, kAudioProcessPropertyIsRunningInput) != 0
            let runningOutput = getUInt32Property(objID, kAudioProcessPropertyIsRunningOutput) != 0
            let ctx = tapContexts[objID] as? ProcessTapContext
            return AudioProcess(id: objID, name: processName(pid), pid: pid,
                                 isRunning: true, isRunningInput: runningInput, isRunningOutput: runningOutput,
                                 icon: NSRunningApplication(processIdentifier: pid)?.icon,
                                 volume: ctx?.params.gain ?? 1.0,
                                 isMuted: ctx?.params.isMuted ?? false,
                                 outputDeviceUID: pinnedOutputRoutes[objID])
        }.sorted { lhs, rhs in
            let lhsActive = lhs.isRunningInput || lhs.isRunningOutput
            let rhsActive = rhs.isRunningInput || rhs.isRunningOutput
            if lhsActive != rhsActive { return lhsActive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if airPodsAutoToggleEnabled { checkAirPodsToggle() }
    }

    // MARK: - Per-process mutators

    func setVolume(_ volume: Float, for objID: AudioObjectID) {
        let clamped = min(max(volume, 0), SoundPreferences.boostCeiling)
        guard let ctx = ensureActiveContext(for: objID) else { return }
        ctx.params.gain = clamped
        updateProcessEntry(objID) { $0.volume = clamped }
        persistSettings(for: objID)
    }

    func setMuted(_ muted: Bool, for objID: AudioObjectID) {
        guard let ctx = ensureActiveContext(for: objID) else { return }
        ctx.params.isMuted = muted
        updateProcessEntry(objID) { $0.isMuted = muted }
        persistSettings(for: objID)
    }

    func setOutputDevice(_ uid: String?, for objID: AudioObjectID) {
        if let uid { pinnedOutputRoutes[objID] = uid } else { pinnedOutputRoutes.removeValue(forKey: objID) }
        guard let ctx = ensureActiveContext(for: objID) else { return }
        let target = uid ?? lastKnownDefaultOutputUID ?? ctx.currentOutputDeviceUID
        ctx.retarget(toOutputDeviceUID: target)
        updateProcessEntry(objID) { $0.outputDeviceUID = uid }
        persistSettings(for: objID)
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    // Returns the process's tap context, creating it on first touch — this is
    // the ONLY place a tap gets created, and only because the user just
    // explicitly moved a volume/mute/output control for this specific
    // process. Seeds gain/mute from whatever was last persisted for it, so a
    // process the user previously customized resumes at that setting the
    // moment they touch it again, without having been silently tapped in the
    // background before they did.
    private func ensureActiveContext(for objID: AudioObjectID) -> ProcessTapContext? {
        if let existing = tapContexts[objID] as? ProcessTapContext { return existing }
        guard let targetUID = pinnedOutputRoutes[objID] ?? lastKnownDefaultOutputUID else { return nil }
        let persisted = processKeys[objID].map { preferences.settings(for: $0) } ?? ProcessAudioSettings()
        guard let ctx = ProcessTapContext(objectID: objID, outputDeviceUID: targetUID,
                                           initialGain: persisted.volume, initialMuted: persisted.isMuted)
        else { return nil }
        tapContexts[objID] = ctx
        return ctx
    }

    private func updateProcessEntry(_ objID: AudioObjectID, _ mutate: (inout AudioProcess) -> Void) {
        guard let idx = processes.firstIndex(where: { $0.id == objID }) else { return }
        mutate(&processes[idx])
    }

    private func persistSettings(for objID: AudioObjectID) {
        guard let ctx = tapContexts[objID] as? ProcessTapContext, let key = processKeys[objID] else { return }
        let settings = ProcessAudioSettings(volume: ctx.params.gain, isMuted: ctx.params.isMuted,
                                             outputDeviceUID: pinnedOutputRoutes[objID])
        preferences.setSettings(settings, for: key)
    }

    // MARK: - Process enumeration

    private func enumerateRunningProcessIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids.filter {
            getUInt32Property($0, kAudioProcessPropertyIsRunning) != 0 && getPID($0) != ownPID
        }
    }

    private func getPID(_ objID: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0; var sz = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(objID, &addr, 0, nil, &sz, &pid)
        return pid
    }

    private func getUInt32Property(_ objID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var val: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(objID, &addr, 0, nil, &sz, &val)
        return val
    }

    private func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: procPathInfoMax)
        proc_name(pid, &buf, UInt32(procPathInfoMax))
        let s = String(cString: buf)
        return s.components(separatedBy: "/").last.map { $0.isEmpty ? "pid \(pid)" : $0 } ?? "pid \(pid)"
    }

    // MARK: - Devices

    private func currentDefaultOutputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
        return id
    }

    private func currentDefaultInputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
        return id
    }

    @discardableResult
    private func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var devID = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
        if status != noErr {
            NSLog("OptimusDiag: setDefaultInputDevice(\(id)) failed status=\(status)")
        }
        return status == noErr
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String {
        guard deviceID != 0 else { return "None" }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &name)
        return name as String
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        guard deviceID != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &uid) == noErr else { return nil }
        return uid as String
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { deviceUID(for: $0) == uid }
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        getUInt32Property(deviceID, kAudioDevicePropertyTransportType)
    }

    private func deviceSummary(for deviceID: AudioDeviceID) -> AudioDeviceSummary {
        AudioDeviceSummary(name: deviceName(for: deviceID), transportType: transportType(for: deviceID))
    }

    private func allDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)
        return ids
    }

    private func hasStreams(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                               mScope: scope,
                                               mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize)
        return dataSize > 0
    }

    private func loadAvailableOutputDevices() -> [AudioOutputDevice] {
        allDevices().compactMap { id -> AudioOutputDevice? in
            guard !ProcessTapContext.activeAggregateDeviceIDs.contains(id),
                  hasStreams(id, scope: kAudioDevicePropertyScopeOutput),
                  let uid = deviceUID(for: id) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: deviceName(for: id), transportType: transportType(for: id))
        }
    }

    // MARK: - AirPods A2DP toggle

    private func checkAirPodsToggle() {
        let micActive = processes.contains { $0.isRunningInput }
        let currentInput = currentDefaultInputDeviceID()
        let inputIsBluetooth = transportType(for: currentInput) == kAudioDeviceTransportTypeBluetooth

        if micActive && inputIsBluetooth {
            if !autoToggleActive, let builtIn = firstBuiltInInputDevice() {
                savedInputDeviceID = currentInput
                preferences.savedInputDeviceUID = deviceUID(for: currentInput)
                setDefaultInputDevice(builtIn)
                autoToggleActive = true
            }
        } else if !micActive && autoToggleActive {
            restoreOriginalInput()
        }
    }

    private func restoreOriginalInput() {
        if let saved = savedInputDeviceID {
            setDefaultInputDevice(saved)
        }
        savedInputDeviceID = nil
        preferences.savedInputDeviceUID = nil
        autoToggleActive = false
    }

    private func firstBuiltInInputDevice() -> AudioDeviceID? {
        allDevices().first {
            transportType(for: $0) == kAudioDeviceTransportTypeBuiltIn && hasStreams($0, scope: kAudioDevicePropertyScopeInput)
        }
    }
}
