import Foundation

/// Detects a "mixed folder": one album folder holding the same release in two
/// or more codecs (e.g. a FLAC rip plus AAC copies bought later). Splitting one
/// codec out into its own sibling folder turns it into a separate pressing the
/// browser can list — and the user can group — as its own version.
public enum AlbumFolderSplitter {
    /// Tracks bucketed by codec (uppercased `formatName`), largest bucket first;
    /// ties break alphabetically for determinism. Unknown-format tracks bucket
    /// under "?" so a split decision never silently drops them.
    /// ponytail: codec-level split only — two same-codec rips mixed in one
    /// folder (different sample rates) would need a finer key.
    public static func codecGroups(for tracks: [LoadedTrack]) -> [(codec: String, tracks: [LoadedTrack])] {
        Dictionary(grouping: tracks) { ($0.track.formatName ?? "?").uppercased() }
            .map { (codec: $0.key, tracks: $0.value) }
            .sorted {
                if $0.tracks.count != $1.tracks.count { return $0.tracks.count > $1.tracks.count }
                return $0.codec < $1.codec
            }
    }
}
