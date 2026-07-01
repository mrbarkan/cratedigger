import Foundation

/// One member pressing of a release: a pointer to a scanned album (by its
/// `AlbumFolderKey`) plus the user's editable edition label ("Gold CD", "JP Vinyl").
public struct VersionMember: Codable, Sendable, Hashable {
    public var key: AlbumFolderKey
    public var editionLabel: String?

    public init(key: AlbumFolderKey, editionLabel: String? = nil) {
        self.key = key
        self.editionLabel = editionLabel
    }
}

/// What a group represents, which changes how `LibraryIndex.build` folds it:
/// - `versionGroup`: N pressings of ONE release; the release shows the primary's
///   track list, the others are alternates (pick a primary).
/// - `boxSet`: N distinct discs/albums sold together; the release shows ALL
///   members' tracks as one whole, expandable to the individual discs.
/// - `compilation`: a various-artists release scattered across artists; the members'
///   tracks are reunited under one "Various Artists" release.
public enum AlbumGroupKind: String, Codable, Sendable, Hashable {
    case versionGroup, boxSet, compilation
}

/// A user-defined grouping of albums. Persisted by `AlbumGroupStore`; folded into
/// the browser by `LibraryIndex.build`. Identity of each member is the existing
/// `AlbumFolderKey`, so grouping is a non-destructive overlay on the scanned library.
public struct AlbumGroup: Codable, Sendable, Hashable, Identifiable {
    /// Stable id (UUID string) generated at creation.
    public var id: String
    /// What kind of group this is (see `AlbumGroupKind`).
    public var kind: AlbumGroupKind
    /// Display title of the release ("Wish You Were Here").
    public var name: String
    /// Owning artist (version groups + box sets; compilations file under Various Artists).
    public var artistID: String
    /// Canonical original release year — drives sorting, regardless of pressing years.
    public var originalYear: Int?
    /// Which member is cover + default playback (matches one member's `key`).
    public var primaryKey: AlbumFolderKey
    /// The members, in display order.
    public var members: [VersionMember]

    public init(id: String, kind: AlbumGroupKind = .versionGroup, name: String, artistID: String,
                originalYear: Int? = nil, primaryKey: AlbumFolderKey, members: [VersionMember]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.artistID = artistID
        self.originalYear = originalYear
        self.primaryKey = primaryKey
        self.members = members
    }

    // Custom decode so groups saved before `kind` existed still load (as version groups).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(AlbumGroupKind.self, forKey: .kind) ?? .versionGroup
        name = try c.decode(String.self, forKey: .name)
        artistID = try c.decode(String.self, forKey: .artistID)
        originalYear = try c.decodeIfPresent(Int.self, forKey: .originalYear)
        primaryKey = try c.decode(AlbumFolderKey.self, forKey: .primaryKey)
        members = try c.decode([VersionMember].self, forKey: .members)
    }
}
