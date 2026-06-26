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

/// A user-defined grouping of several pressings of the same release (e.g. CD,
/// Vinyl, FLAC, Remaster). Persisted by `AlbumGroupStore`; folded into the browser
/// by `LibraryIndex.build`. Identity of each member is the existing `AlbumFolderKey`,
/// so grouping is a non-destructive overlay on the scanned library.
public struct AlbumGroup: Codable, Sendable, Hashable, Identifiable {
    /// Stable id (UUID string) generated at creation.
    public var id: String
    /// Display title of the release ("Wish You Were Here").
    public var name: String
    /// Owning artist (groups never span artists in v1).
    public var artistID: String
    /// Canonical original release year — drives sorting, regardless of pressing years.
    public var originalYear: Int?
    /// Which member is cover + default playback (matches one member's `key`).
    public var primaryKey: AlbumFolderKey
    /// The pressings, in display order.
    public var members: [VersionMember]

    public init(id: String, name: String, artistID: String, originalYear: Int?,
                primaryKey: AlbumFolderKey, members: [VersionMember]) {
        self.id = id
        self.name = name
        self.artistID = artistID
        self.originalYear = originalYear
        self.primaryKey = primaryKey
        self.members = members
    }
}
