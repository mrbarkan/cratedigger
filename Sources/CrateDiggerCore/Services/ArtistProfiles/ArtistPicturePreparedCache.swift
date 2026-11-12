import Foundation

/// The iPod's prepared bytes of artist photos (`ArtistPictureImage.prepare`),
/// kept on the Mac by photo hash, so a transfer reads one small file per
/// artist it writes instead of decoding every artist's full-size photo
/// again. `Application Support/CrateDigger/ArtistPictureCache/<hash>-<edge>.jpg`:
/// a photo's hash names its stored bytes, so what it prepares to never
/// changes; the edge is in the name in case the iPod's size ever does.
/// Everything here is on the Mac; nothing is written to a device.
public struct ArtistPicturePreparedCache: Sendable {
    public let directory: URL

    public init(directory: URL = ArtistPicturePreparedCache.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        applicationSupport.appendingPathComponent("ArtistPictureCache", isDirectory: true)
    }

    /// Where the iPod's prepared pictures were kept before the artist
    /// profiles took them over (`ArtistPictureStore`, now only read by the
    /// migration).
    public static var legacyDirectory: URL {
        applicationSupport.appendingPathComponent("ArtistImages", isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CrateDigger", isDirectory: true)
    }

    /// The iPod's bytes for the photo `hash`: the cached file when there is
    /// one, else `original()` prepared, kept for next time. nil when the
    /// original cannot be read or will not prepare. A hash that is not one
    /// is never cached. Reads, decodes and writes: off the main actor.
    public func prepared(hash: String, original: () -> Data?) -> Data? {
        guard ArtistProfileStore.isHexHash(hash) else { return original().flatMap(ArtistPictureImage.prepare) }
        let url = directory.appendingPathComponent("\(hash)-\(ArtistPictureImage.edge).jpg")
        if let cached = try? Data(contentsOf: url), ArtistPictureImage.isOutputShaped(cached) { return cached }
        guard let source = original(), let prepared = ArtistPictureImage.prepare(source) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try prepared.write(to: url, options: .atomic)
        } catch {
            // Not cached this time; the bytes are still good.
        }
        return prepared
    }

    /// Deletes from the old prepared-picture folder (`legacyDirectory`) the
    /// files of `hashes` (`<hash>.jpg`): the pictures one index folder's
    /// migration carried into profiles it has saved. Never the folder
    /// itself while anything else is in it: every crates folder on this Mac
    /// shares it, and another one not yet migrated still needs its files.
    /// The folder goes once it is empty. Returns how many files went.
    @discardableResult
    public static func removeLegacyFiles(_ hashes: Set<String>, at folder: URL = legacyDirectory,
                                         fileManager: FileManager = .default) -> Int {
        var removed = 0
        for hash in hashes where ArtistProfileStore.isHexHash(hash) {
            let url = folder.appendingPathComponent(hash + ".jpg")
            if fileManager.fileExists(atPath: url.path), (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        if let left = try? fileManager.contentsOfDirectory(atPath: folder.path),
           left.allSatisfy({ $0 == ".DS_Store" }) {
            try? fileManager.removeItem(at: folder)
        }
        return removed
    }
}
