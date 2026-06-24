import Foundation

/// One exported track derived from a `RecordMarker`: the metadata it should carry,
/// the source slice to cut, and a suggested filename stem (before the
/// `OutputPathPlanner` sanitizes it and resolves collisions).
public struct RecordTrackPlan: Sendable, Equatable {
    public let metadata: ConversionMetadata
    public let startSeconds: Double
    public let endSeconds: Double
    /// e.g. "01 The Girl from Ipanema".
    public let baseName: String

    public init(metadata: ConversionMetadata, startSeconds: Double, endSeconds: Double, baseName: String) {
        self.metadata = metadata
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.baseName = baseName
    }
}

/// Expands a Record Divider–marked `LoadedTrack` into one plan per kept track.
/// Pure (no I/O): the conversion layer feeds each plan's `baseName`/`metadata`
/// into `OutputPathPlanner` and attaches the segment to a `ConversionJob`.
public enum RecordTrackPlanner {

    /// One plan per marker, inheriting album-level tags from `baseMetadata`
    /// (defaults to the source track's own metadata) and overriding the per-track
    /// title and sequential track number / total. Returns `[]` for an undivided
    /// track so callers can fall back to a single whole-file job.
    public static func trackPlans(for loadedTrack: LoadedTrack,
                                  baseMetadata: ConversionMetadata? = nil) -> [RecordTrackPlan] {
        guard let markers = loadedTrack.recordMarkers, !markers.isEmpty else { return [] }
        let base = baseMetadata ?? loadedTrack.metadata
        let total = markers.count
        let width = max(2, String(total).count)

        return markers.enumerated().map { index, marker in
            var metadata = base
            metadata.title = marker.title
            metadata.trackNumber = index + 1
            metadata.trackTotal = total
            let number = String(format: "%0\(width)d", index + 1)
            return RecordTrackPlan(
                metadata: metadata,
                startSeconds: marker.startSeconds,
                endSeconds: marker.endSeconds,
                baseName: "\(number) \(marker.title)"
            )
        }
    }
}
