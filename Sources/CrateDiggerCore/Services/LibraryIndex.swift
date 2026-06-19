import Foundation

/// A sort field that can be shown in a menu.
public protocol SortFieldDisplayable: Hashable {
    var displayName: String { get }
}

/// User-selectable ordering for the track list. The canonical album order used
/// when building the index is always `.trackNumber` (disc-aware); this enum lets
/// the browser re-sort what it displays without rebuilding the index.
public enum TrackSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case trackNumber
    case title
    case artist
    case duration

    public var displayName: String {
        switch self {
        case .trackNumber: return "Track #"
        case .title:       return "Title"
        case .artist:      return "Artist"
        case .duration:    return "Duration"
        }
    }
}

/// User-selectable ordering for the artist column.
public enum ArtistSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case name
    case albumCount

    public var displayName: String {
        switch self {
        case .name:       return "Name"
        case .albumCount: return "Albums"
        }
    }
}

/// User-selectable ordering for the album column.
public enum AlbumSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case year
    case title

    public var displayName: String {
        switch self {
        case .year:  return "Year"
        case .title: return "Title"
        }
    }
}

public struct LibraryIndex: Sendable {
    public let artists: [Artist]
    public let allTracks: [LoadedTrack]
    public let albumCount: Int
    public let totalSizeBytes: Int64

    public init(
        artists: [Artist],
        allTracks: [LoadedTrack],
        albumCount: Int,
        totalSizeBytes: Int64
    ) {
        self.artists = artists
        self.allTracks = allTracks
        self.albumCount = albumCount
        self.totalSizeBytes = totalSizeBytes
    }

    public static let empty = LibraryIndex(
        artists: [],
        allTracks: [],
        albumCount: 0,
        totalSizeBytes: 0
    )

    /// Build an `Artist → Album → Track` index from a flat array of loaded tracks.
    /// Grouping keys reuse `OutputPathPlanner.albumFolderKey(for:)` so the inspector,
    /// conversion folder review, and library browser all agree on what an album is.
    public static func build(from loaded: [LoadedTrack]) -> LibraryIndex {
        guard !loaded.isEmpty else { return .empty }

        let planner = OutputPathPlanner()

        var groups: [AlbumFolderKey: [LoadedTrack]] = [:]
        var insertionOrder: [AlbumFolderKey] = []
        for track in loaded {
            let key = planner.albumFolderKey(for: track)
            if groups[key] == nil {
                insertionOrder.append(key)
            }
            groups[key, default: []].append(track)
        }

        var albumsByArtistID: [String: [Album]] = [:]
        var artistDisplayName: [String: String] = [:]

        for key in insertionOrder {
            guard let tracks = groups[key], let representative = tracks.first else { continue }

            let artistName = key.artistBucket
            let artistID = normalizedID(artistName)
            artistDisplayName[artistID] = artistName

            let albumTitle = key.album
            let year = parseYear(key.year)
            let albumID = "\(artistID)::\(normalizedID(albumTitle))::\(key.year)"

            let sortedTracks = sortTracks(tracks)
            let artworkHash = sortedTracks
                .compactMap { $0.track.artworkHash }
                .first ?? representative.track.artworkHash

            let booklet: AlbumBooklet?
            let mediaFormat: MediaFormat?
            if representative.track.fileURL.isFileURL {
                let albumFolder = representative.track.fileURL.deletingLastPathComponent()
                let manifest = ArtworkManifest.load(from: albumFolder)
                booklet = AlbumBooklet.scan(in: albumFolder, manifest: manifest)
                mediaFormat = manifest?.mediaFormat
            } else {
                booklet = nil
                mediaFormat = nil
            }

            let album = Album(
                id: albumID,
                artistID: artistID,
                artistName: artistName,
                title: albumTitle,
                year: year,
                artworkHash: artworkHash,
                tracks: sortedTracks,
                booklet: booklet,
                mediaFormat: mediaFormat
            )

            albumsByArtistID[artistID, default: []].append(album)
        }

        let artists = albumsByArtistID
            .map { (artistID, albums) -> Artist in
                Artist(
                    id: artistID,
                    name: artistDisplayName[artistID] ?? artistID,
                    albums: sortAlbums(albums)
                )
            }
            .sorted(by: artistOrdering)

        let albumCount = artists.reduce(0) { $0 + $1.albums.count }

        let totalBytes = computeTotalSizeBytes(loaded)

        return LibraryIndex(
            artists: artists,
            allTracks: loaded,
            albumCount: albumCount,
            totalSizeBytes: totalBytes
        )
    }

    private static func sortTracks(_ tracks: [LoadedTrack]) -> [LoadedTrack] {
        sortedTracks(tracks, by: .trackNumber, ascending: true)
    }

    /// Sort tracks by the given field. Every field falls back to the natural
    /// disc → track → title order to break ties, so the result is deterministic.
    /// Passing `ascending: false` reverses the whole comparison.
    public static func sortedTracks(
        _ tracks: [LoadedTrack],
        by field: TrackSortField,
        ascending: Bool = true
    ) -> [LoadedTrack] {
        let comparator = ascendingComparator(for: field)
        return tracks.sorted { lhs, rhs in
            ascending ? comparator(lhs, rhs) : comparator(rhs, lhs)
        }
    }

    /// The natural ordering used when building albums: disc, then track number,
    /// then title. Tracks missing a number sort to the end of their disc.
    private static func naturalOrder(_ lhs: LoadedTrack, _ rhs: LoadedTrack) -> Bool {
        let lDisc = lhs.track.discNumber ?? 1
        let rDisc = rhs.track.discNumber ?? 1
        if lDisc != rDisc { return lDisc < rDisc }

        let lTrack = lhs.track.trackNumber ?? Int.max
        let rTrack = rhs.track.trackNumber ?? Int.max
        if lTrack != rTrack { return lTrack < rTrack }

        return lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
    }

    private static func ascendingComparator(
        for field: TrackSortField
    ) -> (LoadedTrack, LoadedTrack) -> Bool {
        switch field {
        case .trackNumber:
            return naturalOrder
        case .title:
            return { lhs, rhs in
                let result = lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title)
                if result != .orderedSame { return result == .orderedAscending }
                return naturalOrder(lhs, rhs)
            }
        case .artist:
            return { lhs, rhs in
                let result = lhs.track.artist.localizedCaseInsensitiveCompare(rhs.track.artist)
                if result != .orderedSame { return result == .orderedAscending }
                return naturalOrder(lhs, rhs)
            }
        case .duration:
            return { lhs, rhs in
                if lhs.track.durationSeconds != rhs.track.durationSeconds {
                    return lhs.track.durationSeconds < rhs.track.durationSeconds
                }
                return naturalOrder(lhs, rhs)
            }
        }
    }

    private static func sortAlbums(_ albums: [Album]) -> [Album] {
        sortedAlbums(albums, by: .year, ascending: true)
    }

    /// Sort albums by year (nil last) or title; the other field breaks ties.
    public static func sortedAlbums(
        _ albums: [Album],
        by field: AlbumSortField,
        ascending: Bool = true
    ) -> [Album] {
        let comparator: (Album, Album) -> Bool
        switch field {
        case .year:
            comparator = { lhs, rhs in
                switch (lhs.year, rhs.year) {
                case let (l?, r?) where l != r: return l < r
                case (nil, _?): return false   // unknown year sorts last
                case (_?, nil): return true
                default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        case .title:
            comparator = { lhs, rhs in
                let result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if result != .orderedSame { return result == .orderedAscending }
                return (lhs.year ?? Int.max) < (rhs.year ?? Int.max)
            }
        }
        return albums.sorted { ascending ? comparator($0, $1) : comparator($1, $0) }
    }

    /// Sort artists by name (unknown last) or album count; name breaks ties.
    public static func sortedArtists(
        _ artists: [Artist],
        by field: ArtistSortField,
        ascending: Bool = true
    ) -> [Artist] {
        let comparator: (Artist, Artist) -> Bool
        switch field {
        case .name:
            comparator = artistOrdering
        case .albumCount:
            comparator = { lhs, rhs in
                if lhs.albums.count != rhs.albums.count { return lhs.albums.count < rhs.albums.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return artists.sorted { ascending ? comparator($0, $1) : comparator($1, $0) }
    }

    private static func artistOrdering(_ lhs: Artist, _ rhs: Artist) -> Bool {
        let lUnknown = isUnknownArtist(lhs.name)
        let rUnknown = isUnknownArtist(rhs.name)
        if lUnknown != rUnknown { return !lUnknown }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func isUnknownArtist(_ name: String) -> Bool {
        name.localizedCaseInsensitiveCompare("Unknown Artist") == .orderedSame
    }

    private static func parseYear(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, let value = Int(trimmed) else { return nil }
        return value
    }

    private static func normalizedID(_ s: String) -> String {
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return stripped
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func computeTotalSizeBytes(_ tracks: [LoadedTrack]) -> Int64 {
        var total: Int64 = 0
        for track in tracks {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: track.track.fileURL.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

public extension LibraryIndex {
    func artist(id: String) -> Artist? { artists.first { $0.id == id } }
    func album(id: String) -> Album? {
        for artist in artists {
            if let match = artist.albums.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}
