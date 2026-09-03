import Foundation

/// What the transport was doing when the app last quit, enough to put it
/// back: the queue as file paths, which one was loaded, how far in, and the
/// source it was playing from. Saved by `LibraryViewModel+Resume`.
public struct PlaybackSnapshot: Codable, Equatable, Sendable {

    /// Bounds the snapshot: the loaded track and up to this many after it. An
    /// "All Records" queue of 14k tracks is not something to serialise on
    /// every pause, and nobody scrolls Up Next past this.
    public static let maxUpNext = 500

    /// `ListeningStore.key(for:)` form. `paths[currentIndex]` is the loaded track.
    public var paths: [String]
    public var currentIndex: Int
    public var positionSeconds: Double
    /// `LibrarySource.persistenceKey` of the source the queue was started from.
    public var sourceKey: String

    /// Build from a live queue, dropping everything before the loaded track
    /// and everything past `maxUpNext` after it. Nil for an empty queue or an
    /// index outside it: there is nothing to come back to.
    public init?(paths: [String], currentIndex: Int, positionSeconds: Double, sourceKey: String) {
        guard paths.indices.contains(currentIndex) else { return nil }
        let end = min(paths.count, currentIndex + 1 + Self.maxUpNext)
        self.paths = Array(paths[currentIndex..<end])
        self.currentIndex = 0
        self.positionSeconds = max(0, positionSeconds)
        self.sourceKey = sourceKey
    }

    public struct Resolved: Equatable, Sendable {
        public let tracks: [LoadedTrack]
        public let currentIndex: Int
        public let positionSeconds: Double
        public let sourceKey: String
    }

    /// Match the saved paths against what the library knows now. Paths the
    /// store has forgotten are dropped and the index shifts to follow the
    /// loaded track; if the loaded track itself is forgotten, or its file is
    /// not on disk, there is nothing worth restoring and this returns nil.
    ///
    /// Other missing files stay in the queue: playback already skips past a
    /// file that fails to open, and dropping them here would make an
    /// unmounted drive look like a shorter queue.
    public func resolve(
        track: (String) -> LoadedTrack?,
        fileExists: (String) -> Bool
    ) -> Resolved? {
        guard paths.indices.contains(currentIndex) else { return nil }
        let loadedPath = paths[currentIndex]
        guard track(loadedPath) != nil, fileExists(loadedPath) else { return nil }

        var tracks: [LoadedTrack] = []
        tracks.reserveCapacity(paths.count)
        var resolvedIndex = 0
        for (offset, path) in paths.enumerated() {
            guard let loaded = track(path) else { continue }
            if offset == currentIndex { resolvedIndex = tracks.count }
            tracks.append(loaded)
        }
        return Resolved(
            tracks: tracks,
            currentIndex: resolvedIndex,
            positionSeconds: positionSeconds,
            sourceKey: sourceKey
        )
    }
}
