import Foundation

/// What the library holds of one artist, for the artist page's "In your
/// library" and "Listening" (spec §2): nothing here is fetched.
///
/// An artist is the index's artist bucket, the album artist where there is
/// one (else the artist), so a compilation counts under Various Artists and
/// a featured guest is not an artist of their own. Keyed like profiles
/// (`PodBoxArtName.folded`), so spellings that fold alike are one artist.
/// A version group counts every pressing's tracks and time, once each: this
/// is what the library holds, not what the album lists.
public struct ArtistLibrarySummary: Equatable, Sendable {
    /// The share of tracks one format needs to be "mostly" that format.
    public static let dominantShare = 0.6
    public static let topTrackCount = 5

    public var albumCount, trackCount: Int
    public var totalSeconds: Double
    /// "FLAC" when ≥ 60% of tracks, else nil (page then lists the top two).
    public var dominantFormat: String?
    /// Every format with its track count, most first, then by name.
    public var formatCounts: [(String, Int)]
    /// From `ListeningStats.dateAdded`; nil when no track has stats.
    public var firstAdded, latestAdded: Date?
    /// The crates holding any of the artist's tracks, by name.
    public var crateNames: [String]
    public var totalPlays: Int
    public var lastPlayed: Date?
    /// Up to 5 by plays, ties by last played; never a track not played.
    public var topTracks: [UUID]

    public init(albumCount: Int = 0, trackCount: Int = 0, totalSeconds: Double = 0, dominantFormat: String? = nil,
                formatCounts: [(String, Int)] = [], firstAdded: Date? = nil, latestAdded: Date? = nil,
                crateNames: [String] = [], totalPlays: Int = 0, lastPlayed: Date? = nil, topTracks: [UUID] = []) {
        self.albumCount = albumCount
        self.trackCount = trackCount
        self.totalSeconds = totalSeconds
        self.dominantFormat = dominantFormat
        self.formatCounts = formatCounts
        self.firstAdded = firstAdded
        self.latestAdded = latestAdded
        self.crateNames = crateNames
        self.totalPlays = totalPlays
        self.lastPlayed = lastPlayed
        self.topTracks = topTracks
    }

    public static func == (lhs: ArtistLibrarySummary, rhs: ArtistLibrarySummary) -> Bool {
        lhs.albumCount == rhs.albumCount && lhs.trackCount == rhs.trackCount && lhs.totalSeconds == rhs.totalSeconds
            && lhs.dominantFormat == rhs.dominantFormat
            && lhs.formatCounts.elementsEqual(rhs.formatCounts, by: { $0.0 == $1.0 && $0.1 == $1.1 })
            && lhs.firstAdded == rhs.firstAdded && lhs.latestAdded == rhs.latestAdded
            && lhs.crateNames == rhs.crateNames && lhs.totalPlays == rhs.totalPlays
            && lhs.lastPlayed == rhs.lastPlayed && lhs.topTracks == rhs.topTracks
    }

    /// Built once per index change for every artist; keyed like profiles.
    /// `listening` and `crates` (crate name to member paths) use the
    /// listening store's path key (`ListeningStore.key(for:)`). An artist
    /// whose name folds to nothing is left out. One pass over the tracks:
    /// run it off the main actor.
    public static func all(index: LibraryIndex, listening: [String: ListeningStats],
                           crates: [String: Set<String>]) -> [String: ArtistLibrarySummary] {
        var tallies: [String: Tally] = [:]
        var keyByPath: [String: String] = [:]
        keyByPath.reserveCapacity(index.allTracks.count)

        for artist in index.artists {
            let key = ArtistProfileKey.key(for: artist.name)
            guard !key.isEmpty else { continue }
            var tally = tallies[key] ?? Tally()
            for album in artist.albums {
                tally.albums += 1
                for loaded in album.tracks { tally.add(loaded, listening: listening, keyByPath: &keyByPath, key: key) }
                for version in album.versions ?? [] {
                    for loaded in version.tracks {
                        tally.add(loaded, listening: listening, keyByPath: &keyByPath, key: key)
                    }
                }
            }
            tallies[key] = tally
        }

        var cratesByKey: [String: Set<String>] = [:]
        for (crate, paths) in crates {
            for path in paths {
                if let key = keyByPath[path] { cratesByKey[key, default: []].insert(crate) }
            }
        }

        return tallies.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.summary(crates: cratesByKey[entry.key] ?? [])
        }
    }

    /// One artist's running counts.
    private struct Tally {
        var albums = 0
        var seen: Set<UUID> = []
        var seconds: Double = 0
        var formats: [String: Int] = [:]
        var firstAdded, latestAdded, lastPlayed: Date?
        var plays = 0
        var played: [(id: UUID, plays: Int, last: Date?, order: Int)] = []

        mutating func add(_ loaded: LoadedTrack, listening: [String: ListeningStats],
                          keyByPath: inout [String: String], key: String) {
            let track = loaded.track
            guard seen.insert(track.id).inserted else { return }
            seconds += track.durationSeconds
            if let format = Self.format(of: track) { formats[format, default: 0] += 1 }
            let path = ListeningStore.key(for: track.fileURL)
            keyByPath[path] = key
            guard let stats = listening[path] else { return }
            firstAdded = min(firstAdded ?? stats.dateAdded, stats.dateAdded)
            latestAdded = max(latestAdded ?? stats.dateAdded, stats.dateAdded)
            plays += stats.playCount
            if let last = stats.lastPlayed { lastPlayed = max(lastPlayed ?? last, last) }
            if stats.playCount > 0 { played.append((track.id, stats.playCount, stats.lastPlayed, played.count)) }
        }

        func summary(crates: Set<String>) -> ArtistLibrarySummary {
            let counts = formats.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { ($0.key, $0.value) }
            let dominant = counts.first.flatMap { top in
                Double(top.1) >= ArtistLibrarySummary.dominantShare * Double(seen.count) ? top.0 : nil
            }
            let top = played.sorted { lhs, rhs in
                if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
                if lhs.last != rhs.last { return (lhs.last ?? .distantPast) > (rhs.last ?? .distantPast) }
                return lhs.order < rhs.order
            }.prefix(ArtistLibrarySummary.topTrackCount).map(\.id)
            return ArtistLibrarySummary(albumCount: albums, trackCount: seen.count, totalSeconds: seconds,
                                        dominantFormat: dominant, formatCounts: counts, firstAdded: firstAdded,
                                        latestAdded: latestAdded, crateNames: crates.sorted(), totalPlays: plays,
                                        lastPlayed: lastPlayed, topTracks: Array(top))
        }

        /// The format's name, else the file's extension in capitals, as the
        /// browser's Format column names it; nil when there is neither.
        static func format(of track: AudioTrack) -> String? {
            if let name = track.formatName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            let fileExtension = track.fileURL.pathExtension.uppercased()
            return fileExtension.isEmpty ? nil : fileExtension
        }
    }
}
