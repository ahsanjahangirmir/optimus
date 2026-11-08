import SwiftUI

struct SoundControlView: View {
    // Owned by ContentView, not here — see the comment there for why: this
    // service must keep running (for the AirPods toggle) regardless of
    // whether this view is currently on screen. @Bindable lets $service.x
    // bindings work the same as they would with a locally-@State-owned
    // instance.
    @Bindable var service: SoundService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceSection
                airPodsSection
                if service.microphonePermissionDenied { permissionBanner }
                processesSection
            }
            .padding(24)
        }
        .navigationTitle("Sound Control")
    }

    private var deviceSection: some View {
        InfoCard(title: "Audio Devices") {
            deviceRow("Output", summary: service.defaultOutputDeviceSummary)
            deviceRow("Input", summary: service.defaultInputDeviceSummary)
        }
    }

    private func deviceRow(_ label: String, summary: AudioDeviceSummary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: transportIcon(summary.transportType)).foregroundStyle(.secondary)
            Text(summary.name).fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.slash.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Capture Permission Denied").font(.headline)
                Text("Optimus needs audio capture access to meter and control per-app volume. Grant access in System Settings, then reopen Sound Control.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open System Settings") { service.openMicrophonePrivacySettings() }
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var airPodsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("AirPods A2DP Preserve Toggle").font(.headline)
                        if service.autoToggleActive && service.airPodsAutoToggleEnabled {
                            Label("Active — using built-in mic", systemImage: "mic.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.1), in: Capsule())
                        }
                    }
                    Text("When enabled, the moment any app starts pulling AirPods microphone input, this switches the system default input to the built-in mic — preserving high-quality A2DP audio for apps like Spotify. Switches back when the call ends.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("⚠️ System-wide default input swap — not per-app routing. All apps share one input device.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Toggle("", isOn: $service.airPodsAutoToggleEnabled)
                    .labelsHidden()
            }
            .padding(16)
        }
        .cardSurface()
    }

    private var processesSection: some View {
        InfoCard(title: "Active Audio Processes") {
            if service.processes.isEmpty {
                Text("No active audio processes detected")
                    .foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(service.processes) { proc in
                    ProcessAudioRow(
                        process: proc,
                        outputOptions: service.availableOutputDevices,
                        onVolumeChange: { service.setVolume($0, for: proc.id) },
                        onMuteToggle: { service.setMuted(!proc.isMuted, for: proc.id) },
                        onOutputChange: { service.setOutputDevice($0, for: proc.id) }
                    )
                    if proc.id != service.processes.last?.id { Divider().padding(.leading, 16) }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Apps aren't tapped by default. Moving an app's volume/mute/output control takes over its audio (may prompt for audio capture access on first use) so the change can take effect — which can trigger macOS's own auto-ducking on that app while active, so avoid adjusting a live call unless you actually need to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

#Preview {
    SoundControlView(service: SoundService()).frame(width: 700)
}
