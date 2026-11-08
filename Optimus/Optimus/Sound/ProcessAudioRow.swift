import SwiftUI
import AppKit

struct ProcessAudioRow: View {
    let process: AudioProcess
    let outputOptions: [AudioOutputDevice]
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onOutputChange: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProcessIconView(icon: process.icon)
                Text(process.name).lineLimit(1)
                Spacer()
                Text("\(process.pid)").font(.caption).foregroundStyle(.secondary)
                Image(systemName: process.isRunningOutput ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(process.isRunningOutput ? .blue : .secondary).frame(width: 20)
                Image(systemName: process.isRunningInput ? "mic.fill" : "mic.slash")
                    .foregroundStyle(process.isRunningInput ? .red : .secondary).frame(width: 20)
            }
            HStack(spacing: 12) {
                Button(action: onMuteToggle) {
                    Image(systemName: process.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(process.isMuted ? "Unmute" : "Mute")

                Slider(value: Binding(get: { process.volume }, set: onVolumeChange),
                       in: 0...SoundPreferences.boostCeiling)
                    .tint(process.volume > 1.0 ? .orange : .accentColor)
                    .disabled(process.isMuted)

                Text(volumeLabel)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Picker("", selection: Binding(get: { process.outputDeviceUID }, set: onOutputChange)) {
                    Text("System Default").tag(String?.none)
                    ForEach(outputOptions) { dev in
                        Label(dev.name, systemImage: transportIcon(dev.transportType)).tag(String?.some(dev.uid))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var volumeLabel: String {
        "\(Int((process.volume * 100).rounded()))%"
    }
}

struct ProcessIconView: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}
