import Foundation

public enum ListeningStoreError: LocalizedError {
    /// The plays file is present but would not decode. Reported instead of
    /// saving, because saving would replace a listening history we failed to
    /// read with whatever little happens to be in memory, and unlike a track
    /// index there is nothing to rebuild it from.
    case unreadableStore(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableStore(let path):
            return "The listening history at \(path) could not be read, so CrateDigger "
                + "has not written over it. Move that file aside to start fresh, or "
                + "restore it from a backup."
        }
    }
}

/// Play counts, skips, ratings and dates for every track in a library, keyed by
/// standardized file path and saved as `library.cdplays` beside
/// `library.cdtracks`.
///
/// Deliberately not a field on `LoadedTrack` in the `TrackStore`, for two
/// reasons. `TrackStore.upsert(_:)` replaces a whole record, and the tag-write,
/// relink, rescan and organiser paths all reconstruct one — every such path
/// would have to remember to carry stats forward, and the cost of forgetting is
/// silently zeroing somebody's history. And `library.cdtracks` is byte-canonical
/// specifically so an unchanged library does not rewrite on save, which a play
/// count, the most frequently changing value in the app, would defeat.
///
/// Same shape as `TrackStore` otherwise: canonical output so backup tools can
/// dedup, and a dirty flag so a save with nothing to write does not happen.
public final class ListeningStore {
    private let fileURL: URL
    private var byPath: [String: ListeningStats] = [:]
    private var isDirty = false
    private var isUnreadable = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// The canonical key for a track: its standardized file path. Same rule as
    /// `TrackStore.key(for:)`, so the two stores agree on identity.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // Must match `save()`. A default decoder reads dates as numeric
        // intervals and would fail on every ISO string this store writes.
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: ListeningStats].self, from: data) else {
            isUnreadable = true
            return
        }
        byPath = decoded
    }

    /// Persist. Canonical bytes: `.sortedKeys` fixes both the path order and the
    /// field order within each record, because Swift seeds its hashing per
    /// process and without it an unchanged file reads as changed to Time
    /// Machine, Dropbox and git on every save.
    public func save() throws {
        if isUnreadable { throw ListeningStoreError.unreadableStore(path: fileURL.path) }
        guard isDirty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(byPath)
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    // MARK: - Reading

    public func stats(path: String) -> ListeningStats? { byPath[path] }

    public var count: Int { byPath.count }
    public var allPaths: [String] { Array(byPath.keys) }

    /// The row for a path, creating an empty one stamped `now` if this is the
    /// first time the library has seen it.
    @discardableResult
    public func statsOrCreate(path: String, now: Date = Date()) -> ListeningStats {
        if let existing = byPath[path] { return existing }
        let fresh = ListeningStats(dateAdded: now)
        byPath[path] = fresh
        isDirty = true
        return fresh
    }

    // MARK: - Writing

    public func recordPlay(path: String, at date: Date = Date()) {
        var stats = statsOrCreate(path: path, now: date)
        stats.recordPlay(at: date)
        byPath[path] = stats
        isDirty = true
    }

    public func recordSkip(path: String) {
        var stats = statsOrCreate(path: path)
        stats.recordSkip()
        byPath[path] = stats
        isDirty = true
    }

    public func setRating(_ rating: Int, path: String) {
        var stats = statsOrCreate(path: path)
        let clamped = min(max(rating, 0), 5)
        guard stats.rating != clamped else { return }
        stats.rating = clamped
        byPath[path] = stats
        isDirty = true
    }

    // MARK: - Housekeeping

    /// Carry a track's history to its new path after a rename, move or
    /// consolidate. If the destination already has a row, the one with more
    /// plays wins: a move must never lose history to a stale row left behind by
    /// an earlier scan of the same file.
    public func repoint(from oldPath: String, to newPath: String) {
        guard oldPath != newPath, let moving = byPath.removeValue(forKey: oldPath) else { return }
        isDirty = true
        guard let existing = byPath[newPath] else {
            byPath[newPath] = moving
            return
        }
        byPath[newPath] = moving.playCount >= existing.playCount ? moving : existing
    }

    /// Forget a track's history, for when it leaves the library for good.
    /// Called from the same purge that drops its `TrackStore` key.
    ///
    /// Deliberately per-path rather than a sweep against a live set: a sweep run
    /// while a library folder happens to be unmounted would delete the history
    /// of every track on it.
    public func remove(path: String) {
        guard byPath.removeValue(forKey: path) != nil else { return }
        isDirty = true
    }

    /// Give every path with no row yet a `dateAdded`, leaving known rows alone.
    ///
    /// ponytail: on a library that predates this file, `dateAdded` is a single
    /// guess for the whole collection rather than a real per-track date, because
    /// there is no record to recover one from. The upgrade path, if it ever
    /// matters, is the file's own creation date. Stamping "today" instead would
    /// make Phase 2's "added this month" rule useless for a year.
    public func backfill(paths: [String], dateAdded: Date) {
        for path in paths where byPath[path] == nil {
            byPath[path] = ListeningStats(dateAdded: dateAdded)
            isDirty = true
        }
    }
}
