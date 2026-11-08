import SwiftUI

enum AppModule: String, CaseIterable, Identifiable {
    case battery = "Battery"
    case systemStats = "CPU / RAM / SSD"
    case storage = "Storage"
    case claudeCode = "Claude Code"
    case fanControl = "Fan Control"
    case sound = "Sound"
    case telemetry = "Telemetry"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .battery: return "battery.100"
        case .systemStats: return "cpu"
        case .storage: return "internaldrive"
        case .claudeCode: return "terminal"
        case .fanControl: return "wind"
        case .sound: return "speaker.wave.2"
        case .telemetry: return "chart.xyaxis.line"
        }
    }
}

struct ContentView: View {
    @State private var selectedModule: AppModule? = .battery
    // Owned here, not inside SoundControlView: the AirPods A2DP-preserving
    // toggle must keep monitoring mic activity in the background regardless
    // of which tab is visible. If it were @State-owned by SoundControlView,
    // switching away from and back to the Sound tab would destroy and
    // recreate the whole service — silently dropping an in-progress swap and
    // stopping monitoring entirely while any other tab is showing.
    @State private var soundService = SoundService()

    var body: some View {
        NavigationSplitView {
            List(AppModule.allCases, selection: $selectedModule) { module in
                Label(module.rawValue, systemImage: module.icon)
                    .tag(module)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
            .navigationTitle("Optimus")
        } detail: {
            Group {
                switch selectedModule {
                case .battery:
                    BatteryView()
                case .systemStats:
                    SystemStatsView()
                case .storage:
                    StorageView()
                case .claudeCode:
                    ClaudeCodeView()
                case .fanControl:
                    FanControlView()
                case .sound:
                    SoundControlView(service: soundService)
                case .telemetry:
                    TelemetryView()
                case nil:
                    Text("Select a module")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swaps the detail pane's default dark-grey window background for
            // a near-black one (see Theme.swift), without touching the
            // sidebar's own vibrancy/blur (that's a separate NavigationSplitView
            // column and isn't affected by this).
            .background(Color.appWindowBackground)
        }
        .task { soundService.start() }
    }
}

#Preview {
    ContentView()
}
