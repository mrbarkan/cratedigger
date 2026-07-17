import Foundation

public enum ArtworkRole: String, Codable, Equatable, Sendable, CaseIterable {
    case auto = "Auto"
    case cover = "Cover"
    /// A secondary front cover (alternate pressing/region art). Saved and shown
    /// as a front image, but never becomes the embedded main cover — that stays
    /// `.cover` (cover.jpg).
    case altCover = "Alt Cover"
    case back = "Back"
    case disc = "Disc"
    case inlay = "Inlay"
    case bookletPage = "Booklet Page"
    case ignore = "Ignore"
}

public extension ArtworkRole {
    /// Display order for the ART grid: the main cover first, then the physical
    /// parts of the package, then booklet pages. Unclassified (`.auto`) and
    /// hidden (`.ignore`) sink to the bottom, where they read as "needs
    /// attention".
    ///
    /// The artwork *viewer* deliberately uses a different order — see
    /// `AlbumArtCatalog.pages`, which sequences a booklet for reading rather
    /// than for editing.
    var sortOrder: Int {
        switch self {
        case .cover:       return 0
        case .altCover:    return 1
        case .back:        return 2
        case .disc:        return 3
        case .inlay:       return 4
        case .bookletPage: return 5
        case .auto:        return 6
        case .ignore:      return 7
        }
    }
}

public struct ArtworkManifest: Codable, Equatable, Sendable {
    public var mediaFormat: MediaFormat?
    public var roles: [String: ArtworkRole] // Key: Filename, Value: Role
    /// Optional vinyl-side label (A, B, …) for `.disc`-roled images, so the
    /// spinning record can show the correct label per the playing track's side.
    /// Filename → side letter. Optional ⇒ old manifests still decode.
    public var discSides: [String: String]?
    /// Optional CD/disc index (1, 2, …) for `.disc`-roled images on multi-disc
    /// sets, so the spinning record shows the art for the playing track's disc.
    /// Filename → disc number. Optional ⇒ old manifests still decode.
    public var discNumbers: [String: Int]?

    public init(mediaFormat: MediaFormat? = nil,
                roles: [String: ArtworkRole] = [:],
                discSides: [String: String]? = nil,
                discNumbers: [String: Int]? = nil) {
        self.mediaFormat = mediaFormat
        self.roles = roles
        self.discSides = discSides
        self.discNumbers = discNumbers
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
