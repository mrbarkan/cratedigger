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

    public init(
        id: String,
        artistID: String,
        artistName: String,
        title: String,
        year: Int?,
        artworkHash: String?,
        tracks: [LoadedTrack],
        booklet: AlbumBooklet? = nil,
        mediaFormat: MediaFormat? = nil
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
