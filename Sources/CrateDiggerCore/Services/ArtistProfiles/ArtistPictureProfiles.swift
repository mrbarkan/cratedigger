import CoreGraphics
import Foundation

/// The artist profiles as a PodBox iPod's pictures read them (spec §7): one
/// snapshot of the store, looked up the way the player matches a person, so
/// `Frank Herbert` on the iPod finds the profile kept as `Herbert, Frank`.
/// The Artist Pictures sheet, the planner's prepared bytes and the names a
/// Find looks up all read profiles through this, so they agree.
public struct ArtistPictureProfiles: Sendable {
    private let byKey: [String: ArtistProfile]
    /// The player's keys (`key` and `altKey` of each profile's name) to a folded key.
    private let byPlayerKey: [UInt32: String]

    public init(_ profiles: [ArtistProfile]) {
        var byKey: [String: ArtistProfile] = [:]
        var byPlayerKey: [UInt32: String] = [:]
        for profile in profiles where !profile.foldedKey.isEmpty {
            byKey[profile.foldedKey] = profile
            for key in Self.playerKeys(profile.displayName) where byPlayerKey[key] == nil {
                byPlayerKey[key] = profile.foldedKey
            }
        }
        self.byKey = byKey
        self.byPlayerKey = byPlayerKey
    }

    /// Every profile in `store`, as it is now.
    public init(store: ArtistProfileStore) {
        self.init(store.allProfiles())
    }

    /// The profile for any spelling the player takes for the same person;
    /// the exact fold first. nil for a name nothing keys.
    public func profile(forName name: String) -> ArtistProfile? {
        let folded = PodBoxArtName.folded(name)
        guard !folded.isEmpty else { return nil }
        if let exact = byKey[folded] { return exact }
        for key in Self.playerKeys(name) {
            if let folded = byPlayerKey[key], let profile = byKey[folded] { return profile }
        }
        return nil
    }

    /// The photo the iPod gets for `profile`: its default, unless the owner
    /// said no photo at all or not on the iPod, and only one whose recorded
    /// size the picture preparer takes (at least 300 px on the short side, not
    /// a banner), so a row never reads as ready for a photo the planner
    /// would then drop. Whether its file is there is the caller's check.
    public static func iPodPhoto(of profile: ArtistProfile?) -> ArtistPhoto? {
        guard let profile, !profile.notOnIPod, let photo = profile.defaultPhotoRef,
              ArtistPictureImage.isAcceptable(CGSize(width: photo.pixelWidth, height: photo.pixelHeight))
        else { return nil }
        return photo
    }

    /// When a search for this artist's picture last found nothing, while
    /// that answer is still trusted (30 days): the later of a picture search
    /// that ended empty and a background lookup that left no photo and no
    /// candidates. nil when the profile has a photo or candidates, or the
    /// answer is older.
    public static func freshNotFound(_ profile: ArtistProfile?, now: Date) -> Date? {
        guard let profile, profile.defaultPhotoRef == nil, profile.photoCandidates.isEmpty else { return nil }
        let lookupFoundNothing = profile.photos.isEmpty ? profile.checkedAt : nil
        guard let latest = [profile.photoSearchedAt, lookupFoundNothing].compactMap({ $0 }).max(),
              now.timeIntervalSince(latest) <= ArtistPictureRecord.notFoundLifetime else { return nil }
        return latest
    }

    private static func playerKeys(_ name: String) -> [UInt32] {
        [PodBoxArtName.key(name), PodBoxArtName.altKey(name)].filter { $0 != 0 }
    }
}
