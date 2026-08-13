import CrateDiggerCore
import SwiftUI

private struct CarbonThemeKey: EnvironmentKey {
    static let defaultValue: CarbonTheme = .linen
}

private struct CarbonGeometryKey: EnvironmentKey {
    static let defaultValue: CarbonGeometry = .standard
}

public extension EnvironmentValues {
    var carbon: CarbonTheme {
        get { self[CarbonThemeKey.self] }
        set { self[CarbonThemeKey.self] = newValue }
    }

    var carbonGeometry: CarbonGeometry {
        get { self[CarbonGeometryKey.self] }
        set { self[CarbonGeometryKey.self] = newValue }
    }
}

public struct CarbonThemed: ViewModifier {
    public let mode: AppearanceMode

    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject private var registry = ThemeRegistry.shared

    public func body(content: Content) -> some View {
        let resolvedSystemScheme: ColorScheme
        switch mode {
        case .light:  resolvedSystemScheme = .light
        case .dark:   resolvedSystemScheme = .dark
        case .system: resolvedSystemScheme = systemScheme
        }

        let fallbackTheme: CarbonTheme = (resolvedSystemScheme == .dark) ? .carbon : .linen
        let selectedThemeID = PreferencesStore.shared.selectedThemeID
        let requestedAppearance: ThemeDefinition.BaseAppearance =
            (resolvedSystemScheme == .dark) ? .dark : .light
        let activeOverride = registry.resolvedTheme(for: selectedThemeID, appearance: requestedAppearance)
        let isAdaptive = registry.activeDefinition(for: selectedThemeID)?.isAdaptive ?? false

        let theme = activeOverride?.theme ?? fallbackTheme
        let geometry = activeOverride?.geometry ?? .standard

        // A single-appearance theme *is* the appearance decision (picking a
        // skin is the whole decision, same as Winamp), so its declared
        // baseAppearance drives preferredColorScheme instead of `mode`.
        //
        // An adaptive theme is the opposite: it ships both looks precisely so
        // it can follow the user's Light/Dark/System choice, so it defers to
        // `mode` the same way no-theme-selected does.
        // While a draft is open the window should match the layer being
        // edited, not the system, so switching to the Light layer shows light
        // chrome immediately.
        let preferredScheme: ColorScheme?
        if activeOverride != nil && (!isAdaptive || registry.draft != nil) {
            preferredScheme = theme.isDark ? .dark : .light
        } else {
            preferredScheme = (mode == .system) ? nil : resolvedSystemScheme
        }

        // Side effect in `body` is intentional and safe here: it's an
        // idempotent write of a plain global (see `ActiveThemeFonts`) derived
        // purely from `selectedThemeID`, consulted by `CarbonFont` — there's
        // no per-call-site path to reach a theme's font overrides otherwise.
        ActiveThemeFonts.overrides = registry.activeDefinition(for: selectedThemeID)?.fonts ?? [:]
        // Same pattern for the OLED glass foreground family — consulted by the
        // `oledFG`/`oledFGo`/`oledMuted` globals in OLEDDisplay.swift.
        ActiveOLEDPalette.foreground = theme.oledForeground
        ActiveOLEDPalette.muted = theme.oledForegroundMuted
        ActiveOLEDPalette.onAir = theme.onAir

        return content
            .environment(\.carbon, theme)
            .environment(\.carbonGeometry, geometry)
            .preferredColorScheme(preferredScheme)
    }
}

public extension View {
    func carbonThemed(mode: AppearanceMode) -> some View {
        modifier(CarbonThemed(mode: mode))
    }
}
