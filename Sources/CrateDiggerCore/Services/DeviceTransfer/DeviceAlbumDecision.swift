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

/// What kind of difference an answer was given for. The same answer does
/// different things to different kinds (Replace swaps counterparts in an
/// upgrade but removes the whole album for another release), so an answer
/// stored for one kind never applies to another.
public enum DeviceDifferenceKind: String, Codable, Sendable {
    /// The same release in another form (audio or art): Replace swaps the
    /// tracks sent for their device counterparts.
    case sameRelease
    /// Another release under the same name: Replace removes the whole
    /// device copy.
    case differentRelease
    /// Nothing differs but a name the write needs is taken by a file
    /// nothing matched: Replace overwrites that file.
    case pathTaken
}

/// An answer made before the review that uses it (stored on a sync queue
/// entry), with the kind of difference it answered.
public struct DeviceStoredDecision: Hashable, Codable, Sendable {
    public let decision: DeviceAlbumDecision
    /// nil for an answer stored before the kind was recorded: it is asked again.
    public let kind: DeviceDifferenceKind?

    public init(_ decision: DeviceAlbumDecision, for kind: DeviceDifferenceKind?) {
        self.decision = decision
        self.kind = kind
    }
}

extension DeviceAlbumComparison {
    /// The kind of difference a differing album has; nil for any other status.
    public var differenceKind: DeviceDifferenceKind? {
        guard status == .differs else { return nil }
        let real = differences.subtracting([.pathTaken])
        if real.isEmpty { return .pathTaken }
        return real.contains(.differentRelease) ? .differentRelease : .sameRelease
    }
}

extension DeviceTransferReview {
    /// Each differing album's kind of difference, for storing beside its answer.
    public var differenceKinds: [DeviceAlbumIdentity: DeviceDifferenceKind] {
        Dictionary(albums.compactMap { album in album.differenceKind.map { (album.identity, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }
}
