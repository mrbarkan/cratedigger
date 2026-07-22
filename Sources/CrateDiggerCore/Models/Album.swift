import Foundation

public struct Album: Identifiable, Sendable, Equatable {
    public let id: String
    public let artistID: String
    public let artistName: String
    public let title: String
    public let year: Int?
    public let artworkHash: String?
    public let tracks: [LoadedTrack]
    public let booklet: AlbumBooklet?
    public let mediaFormat: MediaFormat?
    /// Non-nil when this `Album` is a grouped *release*: its member pressings.
    public let versions: [Album]?
    /// Canonical original release year for a grouped release (drives sorting).
    public let originalYear: Int?
    /// Edition label for a *member* pressing ("Gold CD"); nil otherwise.
    public let editionLabel: String?
    /// For a grouped release, what kind of group it is (drives badge/menu). Nil for
    /// plain albums and member pressings.
    public let groupKind: AlbumGroupKind?
    /// The identity `LibraryIndex.build` grouped this album under — including the
    /// version `discriminator` when same-tagged rips were split by source folder.
    /// Version-group plumbing must use THIS, never re-derive from track tags
    /// (tag-derived keys can't tell two same-tagged versions apart). Nil only on
    /// synthesised release albums.
    public let folderKey: AlbumFolderKey?

    public init(
        id: String,
        artistID: String,
        artistName: String,
        title: String,
        year: Int?,
        artworkHash: String?,
        tracks: [LoadedTrack],
        booklet: AlbumBooklet? = nil,
        mediaFormat: MediaFormat? = nil,
        versions: [Album]? = nil,
        originalYear: Int? = nil,
        editionLabel: String? = nil,
        groupKind: AlbumGroupKind? = nil,
        folderKey: AlbumFolderKey? = nil
    ) {
        self.id = id
        self.artistID = artistID
        self.artistName = artistName
        self.title = title
        self.year = year
        self.artworkHash = artworkHash
        self.tracks = tracks
        self.booklet = booklet
        self.mediaFormat = mediaFormat
        self.versions = versions
        self.originalYear = originalYear
        self.editionLabel = editionLabel
        self.groupKind = groupKind
        self.folderKey = folderKey
    }

    public var trackCount: Int { tracks.count }

    public var totalDurationSeconds: Double {
        tracks.reduce(0) { $0 + $1.track.durationSeconds }
    }

    public var formats: Set<String> {
        Set(tracks.compactMap { $0.track.formatName })
    }

    /// Distinct disc numbers actually present, ascending. Tracks with no disc
    /// tag are treated as disc 1.
    public var discNumbers: [Int] {
        Set(tracks.map { $0.track.discNumber ?? 1 }).sorted()
    }

    /// True when the album's tracks span more than one disc.
    public var isMultiDisc: Bool { discNumbers.count > 1 }

    /// True when this album is a grouped release holding member pressings.
    public var isVersionGroup: Bool { versions != nil }

    /// A copy of this album carrying the given edition label (used when folding a
    /// pressing into a release's `versions`).
    public func with(editionLabel: String?) -> Album {
        Album(id: id, artistID: artistID, artistName: artistName, title: title,
              year: year, artworkHash: artworkHash, tracks: tracks, booklet: booklet,
              mediaFormat: mediaFormat, versions: versions, originalYear: originalYear,
              editionLabel: editionLabel, groupKind: groupKind, folderKey: folderKey)
    }

    /// Number of discs to offer for per-disc artwork: the larger of the discs
    /// present and any explicit disc-total tag.
    public var discCount: Int {
        let fromTracks = discNumbers.last ?? 1
        let fromTotal = tracks.compactMap { $0.track.discTotal }.max() ?? 1
        return max(fromTracks, fromTotal, 1)
    }

    public static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }
}

extension Album: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension LoadedTrack: Identifiable {
    public var id: UUID { track.id }
}
