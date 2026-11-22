import Foundation

/// What makes an album on the device "the same album" as one being sent:
/// the artist bucket and the album title, case- and diacritic-folded, with any
/// disc suffix stripped. Year is deliberately not part of it, so a remaster or
/// reissue meets the copy already on the device and is asked about rather than
/// copied in beside it.
///
/// Built from `OutputPathPlanner.albumFolderKeys(for:)`, the same reconciliation
/// the browser and the conversion planner use, so a compilation without an
/// album-artist tag is one album here too (its "Various Artists" bucket), not
/// one album per performer. Persisted (a remembered Leave it), so the stored
/// strings are already folded and decode as they are.
///
/// Two known limits come with the shared key, accepted rather than worked
/// around: `albumFolderKeys` only reconciles two or more files in one folder,
/// so a single track sent from an untagged compilation (no album artist, no
/// compilation flag) buckets under its own performer and reads as New against
/// the device's Various Artists album; and two different albums sharing a
/// title in one flat device folder are reconciled as one album (by different
/// artists, under Various Artists), so they merge into one identity.
public struct DeviceAlbumIdentity: Hashable, Codable, Sendable {
    /// Folded artist bucket.
    public let artist: String
    /// Folded album title, disc suffix stripped.
    public let album: String

    /// Folds both values, so callers can pass display strings.
    public init(artist: String, album: String) {
        self.artist = Self.fold(artist)
        self.album = Self.fold(OutputPathPlanner.strippingDiscSuffix(album))
    }

    /// The bucket of files with no album tag ("Unknown Album"): loose
    /// singles that share an artist, not a release. The matcher pairs them
    /// by title only and never reads them as another release, so one new
    /// single never offers to replace forty unrelated ones.
    public var isUnknownAlbum: Bool {
        album == Self.unknownAlbum
    }

    private static let unknownAlbum = fold(OutputPathPlanner.defaultUnknownAlbum)

    /// One identity per track id, reconciled across the set via
    /// `OutputPathPlanner.albumFolderKeys` (year dropped, then case/diacritic folded).
    /// Call it once per side (the tracks sent, the device catalog): reconciliation
    /// only ever groups files that share one folder, so mixing the two sides in a
    /// single call gives the same answer, just with more work.
    public static func identities(for tracks: [LoadedTrack]) -> [UUID: DeviceAlbumIdentity] {
        let keys = OutputPathPlanner().albumFolderKeys(for: tracks)
        return keys.mapValues { DeviceAlbumIdentity(artist: $0.artistBucket, album: $0.album) }
    }

    /// Case, diacritic and width folded, whitespace runs collapsed. Shared with
    /// the matcher's title comparison so "Café" and "CAFE" agree everywhere.
    static func fold(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
