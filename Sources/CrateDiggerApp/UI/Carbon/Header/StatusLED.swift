import SwiftUI

/// Tiny activity lamp: a dark unlit ember when idle, solid orange while the
/// app is working. Hover lists what's running. Deliberately static — no pulse
/// animation; a blinking lamp calls more attention than background work
/// deserves, and a static view costs zero GPU while idle (same rule as the
/// Material ban). Mounted in the titlebar's trailing corner (see
/// `TitlebarStatusLED`), the traffic lights' opposite number.
struct StatusLED: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        Circle()
            // Opaque black base so the chassis color never tints the "off"
            // state; the faint orange wash on top reads as an unlit filament.
            .fill(Color.black)
            .overlay(Circle().fill(theme.orange.opacity(model.isWorking ? 1.0 : 0.18)))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: model.isWorking ? theme.orange.opacity(0.6) : .clear, radius: 3)
            .help(helpText)
    }

    private var helpText: String {
        guard model.isWorking else { return "Idle" }
        let labels = model.activityLabels
        return labels.isEmpty ? "Working…" : labels.joined(separator: " · ")
    }
}

/// Self-themed wrapper for hosting `StatusLED` in an `NSTitlebarAccessory-
/// ViewController` — outside `CarbonRootView`'s environment, so it carries its
/// own appearance-mode read and view-model injection.
struct TitlebarStatusLED: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    let model: LibraryViewModel

    var body: some View {
        StatusLED()
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .environmentObject(model)
            .carbonThemed(mode: AppearanceMode(rawValue: appearanceModeRaw) ?? .system)
    }
}
