import Foundation

/// The user's answer for an album whose copy on the device differs from the
/// one being sent. Never pre-selected: an album without one is not written.
public enum DeviceAlbumDecision: String, Codable, Sendable {
    /// Write the album sent and remove the device files it replaces.
    case replace
    /// Write the album sent beside the device copy (a version folder, or
    /// suffixed names where the layout has no album folders).
    case keepBoth
    /// Skip the album and remember that choice for this device.
    case leave
}
