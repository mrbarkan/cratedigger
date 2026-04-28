import SwiftUI

private struct CarbonThemeKey: EnvironmentKey {
    static let defaultValue: CarbonTheme = .linen
}

public extension EnvironmentValues {
    var carbon: CarbonTheme {
        get { self[CarbonThemeKey.self] }
        set { self[CarbonThemeKey.self] = newValue }
    }
}

public struct CarbonThemed: ViewModifier {
    public let mode: AppearanceMode

    @Environment(\.colorScheme) private var systemScheme

    public func body(content: Content) -> some View {
        let resolved: ColorScheme
        switch mode {
        case .light:  resolved = .light
        case .dark:   resolved = .dark
        case .system: resolved = systemScheme
        }

        let theme: CarbonTheme = (resolved == .dark) ? .carbon : .linen

        return content
            .environment(\.carbon, theme)
            .preferredColorScheme(mode == .system ? nil : resolved)
    }
}

public extension View {
    func carbonThemed(mode: AppearanceMode) -> some View {
        modifier(CarbonThemed(mode: mode))
    }
}
