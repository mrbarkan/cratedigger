import Foundation

/// How the main window is laid out: the whole console, or the compact
/// player — one rack unit of art, display and transport with no browser.
/// The raw values are persisted; never rename them.
public enum PlayerLayout: String, CaseIterable, Sendable {
    case full
    case compact

    /// The layout to open in. A compact player has nowhere to put the
    /// first-run flow, so without a chosen library the app always opens full,
    /// whatever was saved.
    public static func launchLayout(saved: PlayerLayout?, libraryChosen: Bool) -> PlayerLayout {
        guard libraryChosen else { return .full }
        return saved ?? .full
    }
}
