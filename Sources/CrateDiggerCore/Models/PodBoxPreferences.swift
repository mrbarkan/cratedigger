import Foundation

/// Where artist pictures go on a PodBox iPod: nowhere, the player's central
/// `/Artwork/People` folder, or a `folder.jpg` in each artist's own folder.
public enum ArtistPictureDestination: String, Codable, Sendable {
    case off, artworkFolder, artistFolders
}

/// Per-device PodBox settings, stored on the device's profile. Every member
/// decodes with its default when absent, so a profile saved by an older
/// build, or holding only some of these, reads without losing anything.
///
/// `artistPictures` stays `.off` for every profile until the owner has run
/// check M5 on the real iPod; nothing turns it on by default.
public struct PodBoxPreferences: Codable, Hashable, Sendable {
    public var sweepsAppleDouble: Bool
    public var artistPictures: ArtistPictureDestination
    public var findsArtistPicturesAutomatically: Bool
    /// Display only: the firmware last seen on the device.
    public var lastSeenFirmware: String?
    /// Manual checks the owner has passed on this iPod ("M5", ...).
    public var passedChecks: Set<String>

    public init() {
        sweepsAppleDouble = true
        artistPictures = .off
        findsArtistPicturesAutomatically = true
        lastSeenFirmware = nil
        passedChecks = []
    }

    enum CodingKeys: String, CodingKey {
        case sweepsAppleDouble, artistPictures, findsArtistPicturesAutomatically, lastSeenFirmware, passedChecks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PodBoxPreferences()
        sweepsAppleDouble = try container.decodeIfPresent(Bool.self, forKey: .sweepsAppleDouble)
            ?? defaults.sweepsAppleDouble
        artistPictures = try container.decodeIfPresent(ArtistPictureDestination.self, forKey: .artistPictures)
            ?? defaults.artistPictures
        findsArtistPicturesAutomatically = try container.decodeIfPresent(
            Bool.self, forKey: .findsArtistPicturesAutomatically) ?? defaults.findsArtistPicturesAutomatically
        lastSeenFirmware = try container.decodeIfPresent(String.self, forKey: .lastSeenFirmware)
        passedChecks = try container.decodeIfPresent(Set<String>.self, forKey: .passedChecks) ?? defaults.passedChecks
    }
}
