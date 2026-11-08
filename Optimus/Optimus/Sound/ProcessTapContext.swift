import Foundation
import CoreAudio
import Darwin

// MARK: - TapParams
// Live-mutable gain/mute state for one process's audio pipeline. Written from
// @MainActor (user moves a slider / taps mute), read on the real-time Core
// Audio IOProc thread every callback. Single aligned-word pointer reads/writes
// are used instead of a lock — safe for a single Float32/Int32 word, avoids
// taking a lock on the real-time audio thread.
final class TapParams {
    private let _gain: UnsafeMutablePointer<Float32>
    private let _muted: UnsafeMutablePointer<Int32>

    var gain: Float32 {
        get { _gain.pointee }
        set { _gain.pointee = newValue }
    }
    var isMuted: Bool {
        get { _muted.pointee != 0 }
        set { _muted.pointee = newValue ? 1 : 0 }
    }

    init(gain: Float32, muted: Bool) {
        _gain = .allocate(capacity: 1); _gain.initialize(to: gain)
        _muted = .allocate(capacity: 1); _muted.initialize(to: muted ? 1 : 0)
    }

    deinit {
        _gain.deallocate()
        _muted.deallocate()
    }
}

// Soft-knee limiter: linear below the threshold, asymptotically approaches
// full scale above it via tanh. Keeps normal 0-100% volume fully transparent
// while preventing harsh digital clipping when boosting above 100%.
private let softLimitThreshold: Float32 = 0.9

@inline(__always)
private func softLimit(_ x: Float32) -> Float32 {
    let mag = abs(x)
    guard mag > softLimitThreshold else { return x }
    let sign: Float32 = x < 0 ? -1 : 1
    let excess = (mag - softLimitThreshold) / (1 - softLimitThreshold)
    return sign * (softLimitThreshold + (1 - softLimitThreshold) * tanhf(excess))
}

// MARK: - ProcessTapContext
// Owns a Core Audio process tap + private aggregate device + IOProc for one
// audio process's volume/mute/boost/output-routing pipeline. The tap is
// `.mutedWhenTapped` (silences the process's direct output while tapped) and
// the aggregate includes a real output subdevice; the IOProc reads captured
// samples, applies live gain/mute from `params`, and writes the processed
// result into `outOutputData` — that write is what forwards audio to the
// real device (a tap alone only captures; nothing plays back unless the
// output buffer is filled).
//
// This is only ever created because the user explicitly touched a
// volume/mute/output control for this specific process — nothing gets a tap
// automatically just by running. Tapping a process (even with a no-op
// unmuted/unity-gain tap) turned out to make macOS apply its own audio-
// ducking policy to that process while the tap exists, which audibly quiets
// things like live calls — so avoid creating one for anything the user isn't
// deliberately taking control of.
@available(macOS 14.2, *)
final class ProcessTapContext {
    // The private per-process aggregate devices we create are only "private"
    // from OTHER processes' device enumeration — the creating process (us)
    // still sees them via kAudioHardwarePropertyDevices. Track our own
    // aggregate device IDs so the output-device picker can filter them out;
    // otherwise every process's own internal plumbing shows up as a
    // selectable "output device".
    static private(set) var activeAggregateDeviceIDs: Set<AudioDeviceID> = []

    let objectID: AudioObjectID
    let params: TapParams

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID: String = ""
    private var aggDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var currentOutputDeviceUID: String

    init?(objectID: AudioObjectID, outputDeviceUID: String, initialGain: Float32 = 1.0, initialMuted: Bool = false) {
        self.objectID = objectID
        self.currentOutputDeviceUID = outputDeviceUID
        self.params = TapParams(gain: initialGain, muted: initialMuted)

        // 1. Create the tap — this may trigger the system audio-capture
        //    permission dialog on first call. `.mutedWhenTapped` silences the
        //    original process's direct-to-hardware output for the duration
        //    we read the tap (continuous here), so this pipeline becomes the
        //    sole path to the speakers while it exists.
        let desc = CATapDescription(stereoMixdownOfProcesses: [objectID])
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tapIDOut = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tapIDOut) == noErr else { return nil }
        tapID = tapIDOut

        // 2. Read back the HAL-assigned persistent tap UID — authoritative,
        //    rather than trusting a client-generated UUID.
        guard let resolvedTapUID = ProcessTapContext.tapUID(for: tapIDOut) else {
            AudioHardwareDestroyProcessTap(tapIDOut)
            return nil
        }
        tapUID = resolvedTapUID

        // 3. Build the aggregate device (real output subdevice + our tap) and
        //    start the IOProc.
        guard buildAggregate(outputDeviceUID: outputDeviceUID) else {
            AudioHardwareDestroyProcessTap(tapIDOut)
            return nil
        }
    }

    // Changes which real device this pipeline forwards to. The tap (and
    // hence live gain/mute state) is unaffected by a route change.
    func retarget(toOutputDeviceUID newUID: String) {
        guard newUID != currentOutputDeviceUID else { return }
        teardownAggregate()
        _ = buildAggregate(outputDeviceUID: newUID)
    }

    private func buildAggregate(outputDeviceUID: String) -> Bool {
        let subDeviceDict: [String: Any] = [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceDriftCompensationKey: NSNumber(value: 1)
        ]
        let tapDict: [String: Any] = [kAudioSubTapUIDKey: tapUID]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Optimus-\(objectID)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1),
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [subDeviceDict],
            kAudioAggregateDeviceTapListKey: [tapDict]
        ]
        var aggIDOut = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggIDOut) == noErr else { return false }

        let paramsRef = params
        var procIDOut: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procIDOut, aggIDOut, nil) { _, inInputData, _, outOutputData, _ in
            let gain = paramsRef.gain
            let muted = paramsRef.isMuted
            let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBL = UnsafeMutableAudioBufferListPointer(outOutputData)
            for (i, inBuf) in inBL.enumerated() {
                guard inBuf.mDataByteSize > 0, let inData = inBuf.mData else { continue }
                let frames = Int(inBuf.mDataByteSize) / MemoryLayout<Float32>.size
                let inSamples = inData.assumingMemoryBound(to: Float32.self)
                guard i < outBL.count, let outData = outBL[i].mData, outBL[i].mDataByteSize > 0 else { continue }
                let outFrames = min(frames, Int(outBL[i].mDataByteSize) / MemoryLayout<Float32>.size)
                let outSamples = outData.assumingMemoryBound(to: Float32.self)
                if muted {
                    for f in 0..<outFrames { outSamples[f] = 0 }
                } else {
                    for f in 0..<outFrames { outSamples[f] = softLimit(inSamples[f] * gain) }
                }
            }
        }
        guard status == noErr, let procID = procIDOut else {
            AudioHardwareDestroyAggregateDevice(aggIDOut)
            return false
        }
        aggDeviceID = aggIDOut
        ioProcID = procID
        currentOutputDeviceUID = outputDeviceUID
        ProcessTapContext.activeAggregateDeviceIDs.insert(aggIDOut)
        AudioDeviceStart(aggIDOut, procID)
        return true
    }

    private func teardownAggregate() {
        if let ioProcID {
            AudioDeviceStop(aggDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggDeviceID != AudioObjectID(kAudioObjectUnknown) {
            ProcessTapContext.activeAggregateDeviceIDs.remove(aggDeviceID)
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            aggDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func tapUID(for tapID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &sz, &uid) == noErr else { return nil }
        return uid as String
    }

    deinit {
        teardownAggregate()
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
}
