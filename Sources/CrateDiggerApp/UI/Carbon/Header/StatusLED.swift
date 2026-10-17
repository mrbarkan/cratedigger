import AppKit
import CrateDiggerCore
import SwiftUI

/// The activity lamp, set into a key. The lamp is a dark unlit ember when
/// idle and solid orange while the app is working. Deliberately static, with
/// no pulse animation: a blinking lamp calls more attention than background
/// work deserves, and a static view costs zero GPU while idle (same rule as
/// the Material ban). Lighting and going out are the one exception, and
/// finite: up at `CarbonMotion.state`, down at `.lampOff`, so a burst of short
/// jobs glows rather than strobes. Mounted in the titlebar's trailing corner
/// (see `TitlebarStatusLED`), the traffic lights' opposite number.
///
/// It is also the NOW screen's animation key: a click steps the LED matrix
/// through the animations ticked in Settings ▸ Interface, Off included
/// (`cycleMatrixAnimation`). It used to be the bare 9 pt lamp, and nobody
/// found that out: a lamp on its own reads as a decoration. So the lamp now
/// sits in a cap seated in a socket, the header keys' own `chassisKey` style,
/// like the illuminated switch on a piece of hardware: it brightens on hover
/// and goes down when pressed. The key is the same 18 pt square the lamp's
/// click target always was, so nothing around it moves. Hover names the
/// current animation, then what's running.
struct StatusLED: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    /// The whole key, socket included. `CompactDeckMetrics.statusLampHitSide`
    /// places the compact window's copy by the same number.
    static let keySide: CGFloat = 18
    private static let lampSide: CGFloat = 7

    var body: some View {
        Button(action: model.cycleMatrixAnimation) {
            lamp
                // The style seats the cap inside its socket's lip, so the cap
                // is the key less a seat on each side.
                .frame(width: Self.keySide - 2 * ChassisKeyMetrics.seat,
                       height: Self.keySide - 2 * ChassisKeyMetrics.seat)
        }
        .buttonStyle(.chassisKey)
        .frame(width: Self.keySide, height: Self.keySide)
        .help(helpText)
        .accessibilityLabel("Display animation")
        .accessibilityValue(model.matrixAnimation.label)
    }

    private var lamp: some View {
        Circle()
            // Opaque black base so the cap's metal never tints the "off"
            // state; the faint orange wash on top reads as an unlit filament.
            .fill(Color.black)
            .overlay(Circle().fill(theme.keyLamp.opacity(model.isWorking ? 1.0 : 0.18)))
            .frame(width: Self.lampSide, height: Self.lampSide)
            // A bezel, so the lamp reads as set into the cap, not painted on.
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .background(Circle().fill(Color.white.opacity(theme.isDark ? 0.08 : 0.5)).offset(y: 0.5))
            .shadow(color: model.isWorking ? theme.keyLamp.opacity(0.6) : .clear, radius: 3)
            .animation(model.isWorking ? CarbonMotion.state : CarbonMotion.lampOff, value: model.isWorking)
            // The cap goes down 1 pt on press; the skirt along its bottom
            // makes the face's visual centre sit that much above the frame's.
            .offset(y: -ChassisKeyMetrics.skirt / 2)
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
            // 14 + the 18 pt key keeps the lamp's centre where it sat when
            // the view was the bare 9 pt lamp.
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
