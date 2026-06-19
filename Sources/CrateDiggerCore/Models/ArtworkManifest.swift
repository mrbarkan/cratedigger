import Foundation

public enum ArtworkRole: String, Codable, Equatable, Sendable, CaseIterable {
    case auto = "Auto"
    case cover = "Cover"
    case back = "Back"
    case disc = "Disc"
    case bookletPage = "Booklet Page"
    case ignore = "Ignore"
}

public struct ArtworkManifest: Codable, Equatable, Sendable {
    public var mediaFormat: MediaFormat?
    public var roles: [String: ArtworkRole] // Key: Filename, Value: Role

    public init(mediaFormat: MediaFormat? = nil, roles: [String: ArtworkRole] = [:]) {
        self.mediaFormat = mediaFormat
        self.roles = roles
    }

    public static let fileName = ".cratedigger-art.json"

    public static func load(from directory: URL) -> ArtworkManifest? {
        let fileURL = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ArtworkManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: fileURL)
    }
}
