import AppKit
import SwiftUI

/// The app's motion vocabulary. Every animation names one of these instead of
/// picking its own curve and duration, so a key, a lamp and a panel move the
/// same way wherever they appear.
///
/// The console is hardware, and the tokens follow how hardware moves: keys
/// and lamps react at once and settle fast, surfaces slide on a damped spring
/// with no overshoot worth seeing, and a lamp going out decays a little
/// slower than it lit, like a filament.
///
/// **Reduce Motion.** Changes of colour, brightness and opacity keep their
/// animation; anything that *moves* (slides, scales, travel, springs) goes
/// through one of the helpers below when the user has asked for less motion:
/// `movement(_:reduceMotion:)` / `withCarbonMovement` shorten it to a quick
/// ease (transitions built with `slide(from:)` become pure dissolves, while
/// a frame change still travels, briefly); `layout(_:reduceMotion:)` drops a
/// geometry-only change to a cut. Use `layout` where the motion *is* the
/// change, such as a pane's width.
enum CarbonMotion {
    // MARK: Feedback: hover and press

    /// A key going down or coming back up.
    static let press: Animation = .easeOut(duration: 0.07)
    /// Hover brightening, cursor-driven highlights.
    static let hover: Animation = .easeOut(duration: 0.12)

    // MARK: State

    /// A control changing state: a toggle, a selection, a lamp lighting,
    /// one label or value giving way to another.
    static let state: Animation = .easeInOut(duration: 0.18)
    /// A lamp going out: slower than it lit.
    static let lampOff: Animation = .easeOut(duration: 0.4)

    // MARK: Movement

    /// Surfaces: a pane collapsing, a panel or popover appearing, a layout
    /// change. Critically damped enough that nothing visibly bounces.
    static let panel: Animation = .spring(response: 0.32, dampingFraction: 0.88)
    /// Large surfaces that take the whole window (gallery, full-screen
    /// player): the same spring, given a little more time to travel.
    static let reveal: Animation = .spring(response: 0.42, dampingFraction: 0.86)

    /// What a movement becomes under Reduce Motion: a quick dissolve.
    static let reducedMovement: Animation = .easeInOut(duration: 0.15)

    /// `animation` when motion is welcome, a quick ease when it is not (a
    /// dissolve for `slide(from:)` transitions). For a view, pass
    /// `@Environment(\.accessibilityReduceMotion)`.
    static func movement(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMovement : animation
    }

    /// For a change that is *only* geometry (a pane's width), where the
    /// dissolve `movement` falls back to would still be a fast slide: instant
    /// under Reduce Motion.
    static func layout(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A list or grid gliding to keep its selection in view. Quicker than any
    /// surface token: arrow keys repeat at ~30 Hz, and a scroll that settles
    /// slower than the key repeats trails the selection it follows. Nil (a
    /// jump) under Reduce Motion: scrolling has no dissolve.
    static func scrollFollow(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    // MARK: Windows (AppKit, so durations rather than Animations)

    /// A dark-room window (full-screen player, artwork viewer, booklet)
    /// fading up: the lights going down.
    static let windowFadeIn: TimeInterval = 0.22
    /// Fading back out, a little quicker: leaving should never feel like
    /// waiting.
    static let windowFadeOut: TimeInterval = 0.16
    /// The main window folding into the compact player or out of it: the
    /// surface spring's response, so the window travels on the same clock as
    /// the panes inside it.
    static let windowResize: TimeInterval = 0.3

    /// A transition that slides in from `edge`, or just fades under Reduce
    /// Motion.
    static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// The system setting, for code that runs outside a view's environment
    /// (view-model actions, AppKit). Views read the environment value.
    @MainActor
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// `withAnimation` for a change that moves something, honouring Reduce
/// Motion. Use plain `withAnimation(CarbonMotion.state)` for colour and
/// opacity changes, which Reduce Motion leaves alone.
@MainActor
@discardableResult
func withCarbonMovement<Result>(_ animation: Animation = CarbonMotion.panel, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(CarbonMotion.movement(animation, reduceMotion: CarbonMotion.prefersReducedMotion), body)
}
