import Foundation

public enum ArtworkRole: String, Codable, Equatable, Sendable, CaseIterable {
    case auto = "Auto"
    case cover = "Cover"
    /// A secondary front cover (alternate pressing/region art). Saved and shown
    /// as a front image, but never becomes the embedded main cover — that stays
    /// `.cover` (cover.jpg).
    case altCover = "Alt Cover"
    /// The sealed copy: front shot through the shrinkwrap, hype stickers on the
    /// plastic and all.
    case wrapped = "Wrapped Cover"
    case back = "Back"
    /// The thin printed edges of a CD case / box set.
    case spine = "Spine"
    /// Inner/outer sleeve (vinyl inner bags, CD paper sleeves).
    case sleeve = "Sleeve"
    case disc = "Disc"
    /// Close-up of the runout groove / matrix etchings — pressing forensics.
    case matrixRunout = "Matrix / Runout"
    case sticker = "Sticker"
    case obi = "Obi"
    case inlay = "Inlay"
    case bookletPage = "Booklet Page"
    case poster = "Poster"
    case ignore = "Ignore"

    /// A manifest written by a newer app version may carry roles this build
    /// doesn't know. Fall back to `.auto` for that one image instead of
    /// failing the whole manifest decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ArtworkRole(rawValue: raw) ?? .auto
    }
}

public extension ArtworkRole {
    /// Display order for the ART grid: the main cover first, then the physical
    /// parts of the package outside-in, then printed matter. Unclassified
    /// (`.auto`) and hidden (`.ignore`) sink to the bottom, where they read as
    /// "needs attention".
    ///
    /// The artwork *viewer* deliberately uses a different order — see
    /// `AlbumArtCatalog.pages`, which sequences a booklet for reading rather
    /// than for editing.
    var sortOrder: Int {
        switch self {
        case .cover:        return 0
        case .altCover:     return 1
        case .wrapped:      return 2
        case .back:         return 3
        case .spine:        return 4
        case .sleeve:       return 5
        case .disc:         return 6
        case .matrixRunout: return 7
        case .sticker:      return 8
        case .obi:          return 9
        case .inlay:        return 10
        case .bookletPage:  return 11
        case .poster:       return 12
        case .auto:         return 13
        case .ignore:       return 14
        }
    }

    /// Menu label. Raw values stay stable (they're the persisted manifest
    /// vocabulary); this is the human wording on top.
    var displayName: String {
        switch self {
        case .cover: return "Main Cover"
        case .disc:  return "Disc / CD"
        case .inlay: return "Inlay / Insert"
        default:     return rawValue
        }
    }

    /// Base filename an imported image of this role is saved under
    /// ("cover.jpg", "matrix_2.png", …). Shared by every import path so the
    /// on-disk vocabulary matches what the filename classifier reads back.
    var suggestedFilenameBase: String {
        switch self {
        case .cover:        return "cover"
        case .altCover:     return "cover_alt"
        case .wrapped:      return "wrapped"
        case .back:         return "back"
        case .spine:        return "spine"
        case .sleeve:       return "sleeve"
        case .disc:         return "disc"
        case .matrixRunout: return "matrix"
        case .sticker:      return "sticker"
        case .obi:          return "obi"
        case .inlay:        return "inlay"
        case .bookletPage:  return "booklet"
        case .poster:       return "poster"
        case .auto:         return "artwork"
        case .ignore:       return "ignored"
        }
    }

    /// The roles a user can assign to an image, in menu order — everything
    /// except the `.auto`/`.ignore` bookkeeping pair.
    static var assignable: [ArtworkRole] {
        allCases.filter { $0 != .auto && $0 != .ignore }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Best role for a Cover Art Archive image given its `types` tags
    /// (https://musicbrainz.org/doc/Cover_Art/Types). When CAA tags several
    /// (a back scan that includes the spine), the dominant subject wins.
    static func forCAATypes(_ types: [String]) -> ArtworkRole {
        let tags = Set(types.map { $0.lowercased() })
        if tags.contains("front") { return .cover }
        if tags.contains("back") { return .back }
        if tags.contains("medium") { return .disc }
        if tags.contains("matrix/runout") { return .matrixRunout }
        if tags.contains("obi") { return .obi }
        if tags.contains("spine") { return .spine }
        if tags.contains("sticker") { return .sticker }
        if tags.contains("sleeve") { return .sleeve }
        if tags.contains("poster") { return .poster }
        if tags.contains("tray") { return .inlay }
        if tags.contains("watermark") { return .ignore }
        return .bookletPage   // booklet, liner, track, unknown — printed matter
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
