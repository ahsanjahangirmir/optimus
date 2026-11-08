import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct OptimusApp: App {
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { applyAppearance(appearanceMode) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Appearance") {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { appearanceMode == mode },
                        set: { isOn in if isOn { select(mode) } }
                    ))
                }
            }
        }
    }

    private func select(_ mode: AppearanceMode) {
        appearanceModeRaw = mode.rawValue
        applyAppearance(mode)
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        NSApp.appearance = mode.nsAppearance
    }
}
