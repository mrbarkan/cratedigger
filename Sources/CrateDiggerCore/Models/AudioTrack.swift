import Foundation

public enum ArtworkSource: String, Codable, Sendable {
    case embedded
    case folderImage = "folder_image"
    case remote
    case none
}

public struct ArtworkDimensions: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct AudioTrack: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double
    public var formatName: String?
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var artworkSource: ArtworkSource
    public var artworkHash: String?
    public var artworkDimensions: ArtworkDimensions?

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        artist: String = "",
        album: String = "",
        durationSeconds: Double = 0,
        formatName: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        artworkSource: ArtworkSource = .none,
        artworkHash: String? = nil,
        artworkDimensions: ArtworkDimensions? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.formatName = formatName
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.artworkSource = artworkSource
        self.artworkHash = artworkHash
        self.artworkDimensions = artworkDimensions
    }

    /// A copy pointing at a new on-disk location, keeping identity and tags —
    /// used when the user relocates a moved/missing file.
    public func withFileURL(_ newURL: URL) -> AudioTrack {
        AudioTrack(
            id: id, fileURL: newURL, title: title, artist: artist, album: album,
            durationSeconds: durationSeconds, formatName: formatName, bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz, year: year, trackNumber: trackNumber, trackTotal: trackTotal,
            discNumber: discNumber, discTotal: discTotal, artworkSource: artworkSource,
            artworkHash: artworkHash, artworkDimensions: artworkDimensions
        )
    }

    /// A copy with a different identity — used when re-reading a file's tags so
    /// the refreshed track keeps the original `id` (selection, queue matching).
    public func withID(_ newID: UUID) -> AudioTrack {
        AudioTrack(
            id: newID, fileURL: fileURL, title: title, artist: artist, album: album,
            durationSeconds: durationSeconds, formatName: formatName, bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz, year: year, trackNumber: trackNumber, trackTotal: trackTotal,
            discNumber: discNumber, discTotal: discTotal, artworkSource: artworkSource,
            artworkHash: artworkHash, artworkDimensions: artworkDimensions
        )
    }
}
