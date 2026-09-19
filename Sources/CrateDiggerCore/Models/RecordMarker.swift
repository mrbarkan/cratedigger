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

public extension RecordMarker {
    /// A downloaded stream's chapters as Record Divider markers, so it plays and
    /// exports track by track. A chapter closes on the next one's start (yt-dlp's
    /// own end times can overlap), the last on the file's real duration, else on
    /// its own end. Fewer than two usable chapters means an ordinary, undivided track.
    static func markers(from chapters: [StreamChapter], duration: Double?) -> [RecordMarker] {
        let sorted = chapters.sorted { $0.startSeconds < $1.startSeconds }
        var markers: [RecordMarker] = []
        for (i, chapter) in sorted.enumerated() {
            let next = sorted.indices.contains(i + 1) ? sorted[i + 1].startSeconds : nil
            guard let end = next ?? duration ?? chapter.endSeconds,
                  end - chapter.startSeconds >= 1 else { continue }
            markers.append(RecordMarker(startSeconds: chapter.startSeconds, endSeconds: end, title: chapter.title))
        }
        return markers.count >= 2 ? markers : []
    }
}
