import Foundation

/// One deduplicated store of every track's metadata, shared by all crates.
/// Crates become membership lists of file paths that resolve against this store,
/// so an album living in several crates is stored once instead of copied into
/// each `.cdlib`. Artwork bytes are NOT here either — they live in `ArtworkStore`
/// keyed by hash (see `ArtworkAsset` Codable). Backed by a single JSON file in
/// the crates folder, so the index stays portable with the crates.
public enum TrackStoreError: LocalizedError {
    /// The index file is present but could not be decoded. Reported instead of
    /// saving, because saving would replace a library we failed to read with
    /// whatever little happens to be in memory.
    case unreadableStore(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableStore(let path):
            return "The library index at \(path) could not be read, so CrateDigger "
                + "has not written over it. Move that file aside to start a fresh "
                + "index, or restore it from a backup."
        }
    }
}

public final class TrackStore {
    private let fileURL: URL
    private var byPath: [String: LoadedTrack] = [:]

    /// Whether the in-memory state has diverged from what is on disk. A full
    /// save re-encodes and rewrites the entire index (~365 ms at 15k tracks on
    /// the main actor), so a save with nothing to write is worth skipping
    /// outright rather than doing faster.
    private var isDirty = false

    /// Set when `load()` found a file it could not decode. See `unreadableStore`.
    private var isUnreadable = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// The canonical key for a track: its standardized file path.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        // No file at all is the normal first-run case: a new, empty store.
        guard let data = try? Data(contentsOf: fileURL) else { return }

        // A file that exists but won't decode is NOT: it means a corrupt or
        // partially written index. Carrying on with an empty store would let the
        // next save overwrite the user's whole library with one track.
        guard let tracks = try? JSONDecoder().decode([LoadedTrack].self, from: data) else {
            isUnreadable = true
            return
        }

        for track in tracks {
            byPath[Self.key(for: track.track.fileURL)] = track
        }
    }

    /// Persist the whole store. Cheap relative to the old per-crate writes — it's
    /// text only (no artwork bytes) and written once regardless of crate count.
    /// Throws so callers can surface a full disk / unmounted volume instead of
    /// silently dropping the user's edits.
    ///
    /// The output is canonical, so an unchanged library re-serializes to
    /// byte-identical bytes. Two things are needed for that, because Swift seeds
    /// its hashing per process: records go out in sorted path order rather than
    /// `byPath.values` order, and `.sortedKeys` fixes the key order *within* each
    /// record (synthesized `Codable` writes into a dictionary-backed container,
    /// so even the field order drifted between launches). Without both, the whole
    /// file read as changed to Time Machine / Dropbox / git on every save even
    /// when nothing had been edited, which delta-based backup can never dedup.
    /// Saving when nothing changed is skipped entirely — see `isDirty`.
    public func save() throws {
        if isUnreadable { throw TrackStoreError.unreadableStore(path: fileURL.path) }
        guard isDirty else { return }

        let tracks = byPath.sorted { $0.key < $1.key }.map(\.value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(tracks)
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    public func track(path: String) -> LoadedTrack? { byPath[path] }

    /// Resolve a crate's membership list to tracks, preserving order and skipping
    /// any path no longer present in the store.
    public func tracks(paths: [String]) -> [LoadedTrack] {
        paths.compactMap { byPath[$0] }
    }

    /// Insert or replace a track, keyed by its file path. In-memory only — call
    /// `save()` to persist.
    ///
    /// Re-upserting an identical track is a no-op and leaves the store clean.
    /// That is the common case, not an edge one: saving a crate upserts every
    /// track it holds, so adding one track to a 900-track crate would otherwise
    /// dirty the store 900 times over for a single real change.
    public func upsert(_ track: LoadedTrack) {
        let key = Self.key(for: track.track.fileURL)
        guard byPath[key] != track else { return }
        byPath[key] = track
        isDirty = true
    }

    public func remove(path: String) {
        guard byPath.removeValue(forKey: path) != nil else { return }
        isDirty = true
    }

    public var count: Int { byPath.count }
    public var allPaths: [String] { Array(byPath.keys) }
    public var allTracks: [LoadedTrack] { Array(byPath.values) }
}
