import Foundation

/// One deduplicated store of every track's metadata, shared by all crates.
/// Crates become membership lists of file paths that resolve against this store,
/// so an album living in several crates is stored once instead of copied into
/// each `.cdlib`. Artwork bytes are NOT here either — they live in `ArtworkStore`
/// keyed by hash (see `ArtworkAsset` Codable). Backed by a single JSON file in
/// the crates folder, so the index stays portable with the crates.
public final class TrackStore {
    private let fileURL: URL
    private var byPath: [String: LoadedTrack] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// The canonical key for a track: its standardized file path.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let tracks = try? JSONDecoder().decode([LoadedTrack].self, from: data) else { return }
        for track in tracks {
            byPath[Self.key(for: track.track.fileURL)] = track
        }
    }

    /// Persist the whole store. Cheap relative to the old per-crate writes — it's
    /// text only (no artwork bytes) and written once regardless of crate count.
    public func save() {
        let tracks = Array(byPath.values)
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func track(path: String) -> LoadedTrack? { byPath[path] }

    /// Resolve a crate's membership list to tracks, preserving order and skipping
    /// any path no longer present in the store.
    public func tracks(paths: [String]) -> [LoadedTrack] {
        paths.compactMap { byPath[$0] }
    }

    /// Insert or replace a track, keyed by its file path. In-memory only — call
    /// `save()` to persist.
    public func upsert(_ track: LoadedTrack) {
        byPath[Self.key(for: track.track.fileURL)] = track
    }

    public func remove(path: String) {
        byPath[path] = nil
    }

    public var count: Int { byPath.count }
    public var allPaths: [String] { Array(byPath.keys) }
    public var allTracks: [LoadedTrack] { Array(byPath.values) }
}
