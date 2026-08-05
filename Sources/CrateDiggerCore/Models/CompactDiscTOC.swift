import CryptoKit
import Foundation

/// An audio CD's table of contents, and the disc ID derived from it.
///
/// A CD carries no tags at all — macOS mounts one as `1 Audio Track.aiff`,
/// `2 Audio Track.aiff`, … on a volume called "Audio CD". Fuzzy matching has
/// nothing to work with. But the TOC (where each track starts, and where the
/// disc ends) is effectively a fingerprint of the pressing, and MusicBrainz
/// indexes releases by a hash of exactly that. So a disc with zero metadata can
/// still be identified *exactly*, before a single sector is ripped.
///
/// macOS writes the TOC to `.TOC.plist` at the root of the mounted volume, in
/// the same absolute-sector form MusicBrainz expects (track 1 at 150 — the
/// 2-second pregap is already included), so no conversion is needed.
public struct CompactDiscTOC: Equatable, Hashable, Sendable {
    public let firstTrack: Int
    public let lastTrack: Int
    /// Where the audio ends, in absolute sectors.
    public let leadoutBlock: Int
    /// Absolute start sector per audio track, in track order.
    public let trackOffsets: [Int]

    public init(firstTrack: Int, lastTrack: Int, leadoutBlock: Int, trackOffsets: [Int]) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadoutBlock = leadoutBlock
        self.trackOffsets = trackOffsets
    }

    public var trackCount: Int { trackOffsets.count }

    /// Per-track length in sectors — each track runs to the next one's start,
    /// and the last runs to the leadout. 75 sectors = 1 second.
    public var trackLengthsInSectors: [Int] {
        trackOffsets.indices.map { i in
            let end = i + 1 < trackOffsets.count ? trackOffsets[i + 1] : leadoutBlock
            return max(0, end - trackOffsets[i])
        }
    }

    public var trackDurationsInSeconds: [Double] {
        trackLengthsInSectors.map { Double($0) / 75.0 }
    }

    // MARK: - Disc ID

    /// The MusicBrainz disc ID.
    ///
    /// SHA-1 over a fixed-width uppercase-hex string — first track, last track,
    /// leadout, then exactly 99 track offsets zero-padded out — base64'd with
    /// `+/=` swapped for `._-` so it is URL-safe. The 99 slots are part of the
    /// spec, not padding we chose: a shorter string hashes differently.
    public var musicBrainzDiscID: String {
        var payload = String(format: "%02X", firstTrack)
        payload += String(format: "%02X", lastTrack)
        payload += String(format: "%08X", leadoutBlock)
        for slot in 0..<99 {
            payload += String(format: "%08X", slot < trackOffsets.count ? trackOffsets[slot] : 0)
        }
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// The `toc=` form MusicBrainz accepts when a disc ID isn't in the database
    /// — it drives the "attach this disc to a release" web flow.
    public var musicBrainzTOCParameter: String {
        ([firstTrack, lastTrack, leadoutBlock] + trackOffsets)
            .map(String.init)
            .joined(separator: "+")
    }

    // MARK: - Reading macOS's `.TOC.plist`

    public static let plistFilename = ".TOC.plist"

    /// Parse the `.TOC.plist` macOS writes to a mounted audio CD.
    /// Data tracks are skipped — a mixed-mode disc's data session is not audio
    /// and including it would change the disc ID.
    public init?(tocPlistData data: Data) {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let sessions = root["Sessions"] as? [[String: Any]],
              let session = sessions.first,
              let first = session["First Track"] as? Int,
              let last = session["Last Track"] as? Int,
              let leadout = session["Leadout Block"] as? Int,
              let trackArray = session["Track Array"] as? [[String: Any]]
        else { return nil }

        let offsets: [Int] = trackArray.compactMap { entry in
            let isData = (entry["Data"] as? Bool) ?? false
            guard !isData, let start = entry["Start Block"] as? Int else { return nil }
            return start
        }
        guard !offsets.isEmpty, leadout > 0 else { return nil }

        self.init(firstTrack: first, lastTrack: last, leadoutBlock: leadout, trackOffsets: offsets)
    }

    /// Read the TOC from a mounted CD volume, or nil if it isn't an audio CD.
    public static func read(volumeURL: URL, fileManager: FileManager = .default) -> CompactDiscTOC? {
        let url = volumeURL.appendingPathComponent(plistFilename)
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        return CompactDiscTOC(tocPlistData: data)
    }
}
