import Foundation

/// The pull-out panel under the mini player: what is coming, or what to put
/// on. Which face it opens on is decided here, so the rule is written once
/// and tested rather than re-derived in a view body.
public enum MiniPlayerPanelTab: String, CaseIterable, Sendable {
    case upNext
    case sources

    public var title: String {
        switch self {
        case .upNext:  return "UP NEXT"
        case .sources: return "SOURCES"
        }
    }

    /// The face the panel shows when it opens.
    ///
    /// With a record on, the question is "what's next"; with nothing on, or
    /// a stream on (which has no queue), the only useful face is the one that
    /// starts something.
    public static func initial(isPlaying: Bool, isStream: Bool) -> MiniPlayerPanelTab {
        (isPlaying && !isStream) ? .upNext : .sources
    }

    /// Whether the mini player should appear with the panel already out.
    /// A player showing "Nothing Playing" has exactly one thing to offer.
    public static func opensExpanded(isPlaying: Bool) -> Bool {
        !isPlaying
    }
}
