import Foundation
import CoreAudio

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
}

struct AudioDeviceSummary: Equatable {
    var name: String = "\u{2014}"
    var transportType: UInt32 = 0
}

func transportIcon(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn:
        return "laptopcomputer"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        return "wave.3.right"
    case kAudioDeviceTransportTypeUSB:
        return "cable.connector"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
        return "tv"
    case kAudioDeviceTransportTypeAirPlay:
        return "airplayaudio"
    case kAudioDeviceTransportTypeThunderbolt:
        return "bolt"
    default:
        return "speaker.wave.2"
    }
}
