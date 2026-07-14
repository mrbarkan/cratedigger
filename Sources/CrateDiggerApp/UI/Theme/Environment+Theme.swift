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
        let activeOverride = registry.resolvedTheme(for: selectedThemeID)

        let theme = activeOverride?.theme ?? fallbackTheme
        let geometry = activeOverride?.geometry ?? .standard

        // A specific installed theme *is* the appearance decision (picking a
        // skin is the whole decision, same as Winamp) — its declared
        // baseAppearance drives preferredColorScheme instead of `mode`. With
        // no theme selected, this is byte-for-byte today's behavior.
        let preferredScheme: ColorScheme? = activeOverride != nil
            ? (theme.isDark ? .dark : .light)
            : (mode == .system ? nil : resolvedSystemScheme)

        // Side effect in `body` is intentional and safe here: it's an
        // idempotent write of a plain global (see `ActiveThemeFonts`) derived
        // purely from `selectedThemeID`, consulted by `CarbonFont` — there's
        // no per-call-site path to reach a theme's font overrides otherwise.
        ActiveThemeFonts.overrides = registry.manifest(for: selectedThemeID)?.definition.fonts ?? [:]

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
