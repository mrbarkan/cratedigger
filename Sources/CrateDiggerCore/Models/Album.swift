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
