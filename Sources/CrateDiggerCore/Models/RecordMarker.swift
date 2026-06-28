import Foundation

/// A single detected/edited track within a longer recording — e.g. one song on a
/// vinyl-side rip captured as a continuous file. One marker == one *kept* track:
/// playback navigates between markers, and conversion/export cuts one output file
/// per marker. Audio not covered by any marker is "skipped" — audible in playback,
/// omitted from export. Analogous to `StreamChapter` for YouTube mixes.
public struct RecordMarker: Codable, Sendable, Hashable, Identifiable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var title: String

    /// Stable identity for SwiftUI lists (markers are ordered by start time).
    public var id: Double { startSeconds }

    public init(startSeconds: Double, endSeconds: Double, title: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
    }

    /// Length of this track in seconds.
    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}
