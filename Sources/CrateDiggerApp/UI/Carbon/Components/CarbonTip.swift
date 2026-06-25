import SwiftUI

/// A hover tooltip that respects the user's "Show hover tips" preference.
///
/// Uses the native macOS help tooltip, but only when tips are enabled — when the
/// user turns them off (Preferences → Advanced) no help is attached at all. The
/// `@AppStorage` key mirrors `PreferencesStore.showHoverTips`, so flipping the
/// preference updates every tip live without any wiring.
private struct CarbonTip: ViewModifier {
    @AppStorage("cratedigger.ui.showHoverTips") private var tipsEnabled: Bool = true
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if tipsEnabled, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

extension View {
    /// A hover tooltip explaining what a control does. Shown only when the user
    /// has hover tips enabled. Drop-in for `.help(_:)` so the preference governs
    /// every tip from one place.
    func carbonTip(_ text: String) -> some View {
        modifier(CarbonTip(text: text))
    }
}
