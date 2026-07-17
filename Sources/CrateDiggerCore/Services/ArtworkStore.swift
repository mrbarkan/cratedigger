import Foundation

/// Content-addressed, on-disk **thumbnail** cache for artwork. Each cover is
/// written once under its own SHA-256 hash, so identical art shared by many
/// tracks/albums/crates is stored a single time.
///
/// This is a cache, not a library: canonical artwork lives with the music
/// (embedded in the audio file, or `cover.jpg` in the album folder), so
/// deleting an album folder deletes its art for real. What's kept here is only
/// what the cache is actually for — drawing covers when the source is slow or
/// offline — at thumbnail size (see `ArtworkThumbnail`). Storing full-resolution
/// blobs here instead grew to gigabytes of pure duplication, which is why 1.1.0
/// migrates the old store (`migrateLegacyFullResolutionStore`).
///
/// Full-resolution bytes for *re-embedding* (conversion, device transfer) come
/// from the source file — never from here. See `ArtworkService.hydrated`.
public final class ArtworkStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `Application Support/CrateDigger/Thumbnails` — app-owned and disposable.
    public static var defaultDirectory: URL {
        appSupportDirectory.appendingPathComponent("Thumbnails")
    }

    /// `Application Support/CrateDigger/Artwork` — the pre-1.1.0 full-resolution
    /// store, migrated then deleted on first launch.
    public static var legacyFullResolutionDirectory: URL {
        appSupportDirectory.appendingPathComponent("Artwork")
    }

    private static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CrateDigger")
    }

    private func url(for hash: String) -> URL {
        directory.appendingPathComponent(hash)
    }

    public func contains(_ hash: String) -> Bool {
        fileManager.fileExists(atPath: url(for: hash).path)
    }

    /// Write-once: a hash addresses identical bytes, so an existing entry is
    /// never rewritten. Empty data is ignored. Image data is downscaled to a
    /// thumbnail first; anything that isn't a decodable image is stored as-is
    /// (nothing in the app produces such an asset — `ArtworkService` only builds
    /// assets from bytes it could decode — so this is a conservative fallback,
    /// not a supported path).
    public func put(_ data: Data, for hash: String) {
        guard !data.isEmpty else { return }
        let destination = url(for: hash)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        let thumbnail = ArtworkThumbnail.encode(data) ?? data
        try? thumbnail.write(to: destination, options: .atomic)
    }

    public func data(for hash: String) -> Data? {
        try? Data(contentsOf: url(for: hash))
    }

    /// Drop one cached thumbnail — used when its source art is deleted, so the
    /// cache doesn't keep a cover the user removed. Silent when absent: the
    /// thumbnail may simply never have been drawn.
    public func remove(_ hash: String) {
        try? fileManager.removeItem(at: url(for: hash))
    }

    /// Drop every cached thumbnail. Safe at any time — thumbnails regenerate
    /// from the source art the next time a cover is drawn.
    public func clear() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Approximate on-disk size, for the Preferences readout.
    public func diskSizeBytes() -> Int {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// One-time migration off the pre-1.1.0 full-resolution store: squeeze each
    /// blob down into this thumbnail cache, then delete the old directory so the
    /// disk space comes back immediately. Blobs that fail individually are
    /// skipped — worst case that cover re-caches the next time it's drawn.
    /// No-op when the legacy directory is absent (i.e. every launch after the
    /// first). Returns the number of bytes reclaimed, for logging.
    @discardableResult
    public func migrateLegacyFullResolutionStore(
        at legacyDirectory: URL = ArtworkStore.legacyFullResolutionDirectory
    ) -> Int {
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return 0 }

        let blobs = (try? fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        var reclaimed = 0
        for blob in blobs {
            reclaimed += (try? blob.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Legacy blobs were named by bare hash, which is this store's key too.
            guard let data = try? Data(contentsOf: blob) else { continue }
            put(data, for: blob.lastPathComponent)
        }

        try? fileManager.removeItem(at: legacyDirectory)
        return reclaimed
    }
}
