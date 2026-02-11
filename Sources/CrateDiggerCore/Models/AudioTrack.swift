import Foundation

public enum ArtworkSource: String, Codable, Sendable {
    case embedded
    case folderImage = "folder_image"
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

public struct AudioTrack: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double
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
        self.artworkSource = artworkSource
        self.artworkHash = artworkHash
        self.artworkDimensions = artworkDimensions
    }
}
