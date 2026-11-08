import SwiftUI
import AppKit

/// Centralized colors so every module's cards/backgrounds move together
/// when the app's look changes, instead of each view hardcoding `.regularMaterial`.
/// Both colors are backed by dynamic `NSColor`s so they track the *effective*
/// appearance automatically — including when the user overrides it via the
/// Appearance menu (see `AppearanceMode` in OptimusApp.swift) — without any
/// view needing to read `\.colorScheme` itself.
extension Color {
    static let appWindowBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.035, alpha: 1) : .windowBackgroundColor
    })

    /// Card/panel surface. Dark mode gets a flat near-black charcoal (a shade
    /// lighter than the window background, for separation); light mode keeps
    /// the same neutral panel tone `.regularMaterial` used to produce.
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.09, alpha: 1) : .controlBackgroundColor
    })

    /// Hairline border to give flat cards definition against the near-black
    /// background now that they no longer get depth from material blur.
    static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)
    })
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension View {
    /// Replaces the old `.background(.regularMaterial, in: RoundedRectangle(cornerRadius:))`
    /// card recipe used across every module.
    func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        background(Color.cardSurface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.cardBorder, lineWidth: 1)
            )
    }
}
