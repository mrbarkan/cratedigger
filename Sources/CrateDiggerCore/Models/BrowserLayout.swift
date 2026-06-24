import Foundation

/// How the library browser arranges its columns. Lets the user collapse the
/// default 3-pane `Artist · Album · Track` browser down to fewer panes.
public enum BrowserLayout: String, Codable, Sendable, CaseIterable, Hashable {
    /// Artist · Album · Track (default).
    case full
    /// Album · Track — the album pane lists every album across all artists.
    case albumTrack
    /// A single flat list of every track in the source.
    case track

    /// Descriptive label for the menu item.
    public var title: String {
        switch self {
        case .full:       return "Artist · Album · Track"
        case .albumTrack: return "Album · Track"
        case .track:      return "Track"
        }
    }

    /// SF Symbol shown on the browser header control.
    public var iconName: String {
        switch self {
        case .full:       return "rectangle.split.3x1"
        case .albumTrack: return "rectangle.split.2x1"
        case .track:      return "rectangle"
        }
    }
}
