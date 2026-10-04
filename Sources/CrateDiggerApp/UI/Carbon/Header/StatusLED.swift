import AppKit
import CrateDiggerCore
import SwiftUI

/// Tiny activity lamp: a dark unlit ember when idle, solid orange while the
/// app is working. Deliberately static — no pulse animation; a blinking lamp
/// calls more attention than background work deserves, and a static view
/// costs zero GPU while idle (same rule as the Material ban). Mounted in the
/// titlebar's trailing corner (see `TitlebarStatusLED`), the traffic lights'
/// opposite number.
///
/// It is also the NOW screen's animation key: a click steps the LED matrix
/// through the animations ticked in Settings ▸ Interface, Off included
/// (`cycleMatrixAnimation`). The lamp
/// stays 9 pt, but the click lands anywhere in an 18 pt square around it, so
/// it can be hit without aiming. Hover names the current animation, then
/// what's running.
struct StatusLED: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        Button(action: model.cycleMatrixAnimation) {
            Circle()
                // Opaque black base so the chassis color never tints the "off"
                // state; the faint orange wash on top reads as an unlit filament.
                .fill(Color.black)
                .overlay(Circle().fill(theme.keyLamp.opacity(model.isWorking ? 1.0 : 0.18)))
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                .shadow(color: model.isWorking ? theme.keyLamp.opacity(0.6) : .clear, radius: 3)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Display animation")
        .accessibilityValue(model.matrixAnimation.label)
    }

    private var helpText: String {
        let animation = "Animation: \(model.matrixAnimation.label). Click to change."
        guard model.isWorking else { return animation }
        let labels = model.activityLabels
        return animation + "\n" + (labels.isEmpty ? "Working…" : labels.joined(separator: " · "))
    }
}

/// Self-themed wrapper for hosting `StatusLED` in an `NSTitlebarAccessory-
/// ViewController` — outside `CarbonRootView`'s environment, so it carries its
/// own appearance-mode read and view-model injection. Hosted in a
/// `TitlebarButtonHostingView`, which is what lets the click reach the button.
struct TitlebarStatusLED: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    let model: LibraryViewModel

    var body: some View {
        StatusLED()
            // 14 + the 18 pt hit square keeps the lamp's centre where it sat
            // when the view was the bare 9 pt lamp.
            .padding(.trailing, 14)
            .padding(.vertical, 3)
            .environmentObject(model)
            .carbonThemed(mode: AppearanceMode(rawValue: appearanceModeRaw) ?? .system)
    }
}

/// A hosting view for a control in the titlebar. The titlebar treats a mouse
/// down over any view that says it can move the window as the start of a
/// window drag, and a plain `NSHostingView` says so (it is not opaque), so a
/// SwiftUI button hosted there could be dragged by but not reliably clicked.
/// This one claims its clicks for its content, including the first click on
/// an inactive window, as the traffic lights do.
final class TitlebarButtonHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
