import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

public protocol ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile, maxDimension: Int?) throws -> ArtworkAsset
}

public extension ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile, maxDimension: Int?) throws -> ArtworkAsset {
        try prepareCompatibleArtwork(asset: asset, profile: profile)
    }
}

public enum ArtworkServiceError: Error {
    case couldNotDecodeImage
    case couldNotEncodeCompatibleJPEG
}

/// Hand-off box for a value that is safe to move across concurrency domains
/// but lacks a Sendable annotation on our deployment target — e.g. `NSImage`,
/// whose conformance only ships in macOS 14. Only for freshly-created values
/// handed to exactly one receiver, never for shared mutable state.
public struct UncheckedSendableBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

public final class ArtworkService: ArtworkPreparing {
    private let fileManager: FileManager
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// Full-resolution source image bytes, kept only to (re)generate thumbnails.
    /// Cost-limited so a large scan can't grow it without bound — `NSData` is its
    /// own LRU store and is internally thread-safe.
    /// A miss simply yields no thumbnail (a handled `nil`), never a crash.
    private let dataCache = NSCache<NSString, NSData>()
    /// Persistent, content-addressed backing for `dataCache`. When set, source
    /// bytes survive relaunches and offline source drives; a thumbnail miss can
    /// reload from disk by hash instead of yielding a placeholder. `nil` keeps
    /// the pure in-memory behavior (used by Core unit tests).
    private let store: ArtworkStore?
    /// Per-folder cover lookup memo (negative results included) so a scan probes
    /// each album folder's candidate files once instead of ~63 syscalls + a full
    /// read + decode + hash per *track*. Guarded by `folderMemoLock` — the scan
    /// resolves tracks concurrently. Cleared at the start of every scan.
    private var folderArtworkMemo: [String: ArtworkAsset?] = [:]
    private let folderMemoLock = NSLock()
    /// `prepareCompatibleArtwork` output keyed by (source hash, profile, max
    /// dimension). A batch conversion calls prepare once per *job*, so identical
    /// covers shared across an album would otherwise re-decode/re-encode
    /// thousands of times. NSCache: thread-safe and cost-bounded.
    private let preparedArtworkCache = NSCache<NSString, PreparedArtworkBox>()

    private final class PreparedArtworkBox {
        let asset: ArtworkAsset
        init(_ asset: ArtworkAsset) { self.asset = asset }
    }

    public init(fileManager: FileManager = .default, store: ArtworkStore? = nil) {
        self.fileManager = fileManager
        self.store = store
        thumbnailCache.countLimit = 512
        thumbnailCache.totalCostLimit = 48 * 1024 * 1024   // ~48 MB of decoded thumbnails
        dataCache.totalCostLimit = 96 * 1024 * 1024        // ~96 MB of source image data
        preparedArtworkCache.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of prepared covers
    }

    public func cacheRemoteArtworkURL(_ hash: String, url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else {
                return
            }
            let asset = ArtworkAsset(
                source: .remote,
                hash: hash,
                dimensions: ArtworkDimensions(width: Int(image.size.width), height: Int(image.size.height)),
                data: data
            )
            self.ingest(asset)
        }
    }

    public func resolveArtwork(trackURL: URL) async -> ArtworkAsset? {
        await resolveArtwork(trackURL: trackURL, preloadedMetadata: nil)
    }

    /// `preloadedMetadata` lets the scan hand over the AVAsset metadata items it
    /// already loaded (common + every format), so embedded-art extraction skips
    /// constructing and re-loading a second AVURLAsset for the same file.
    public func resolveArtwork(trackURL: URL, preloadedMetadata: [AVMetadataItem]?) async -> ArtworkAsset? {
        if let embedded = await embeddedArtwork(for: trackURL, preloadedMetadata: preloadedMetadata) {
            return sharingBytes(embedded, storeData(embedded.data, for: embedded.hash))
        }

        if let folder = memoizedFolderArtwork(for: trackURL) {
            return sharingBytes(folder, storeData(folder.data, for: folder.hash))
        }

        return nil
    }

    /// Drop the per-folder cover memo so the next lookup re-reads from disk.
    /// Called at the start of every scan (covers can change between scans).
    public func clearFolderArtworkMemo() {
        folderMemoLock.lock()
        folderArtworkMemo.removeAll()
        folderMemoLock.unlock()
    }

    /// Make `asset.data` available to `generateThumbnail(artworkHash:size:)`.
    /// Used after fetching artwork from sources outside the scan pipeline (e.g. iTunes).
    public func ingest(_ asset: ArtworkAsset) {
        storeData(asset.data, for: asset.hash)
    }

    /// Forget one cover's cached thumbnail — used when its source art is deleted.
    ///
    /// Only the on-disk store is pruned. The in-memory NSCaches are keyed
    /// `hash-WxH` / `hash-tN` and NSCache cannot enumerate its keys, so per-key
    /// eviction would mean tracking every key by hand — for entries that nothing
    /// references once the index rebuilds, in a cache that already evicts under
    /// pressure. Not worth the bookkeeping.
    public func removeCached(hash: String) {
        store?.remove(hash)
    }

    /// Refill an asset's full-resolution `data`. Assets decoded from a `.cdlib`
    /// come back with empty `data` (the crate stores only the hash), so
    /// conversion/transfer must rehydrate them before re-embedding artwork.
    ///
    /// Bytes come from the full-resolution in-memory cache, or failing that are
    /// re-read from the track's own file/folder. The on-disk store is
    /// deliberately NOT consulted: it holds display *thumbnails*, and baking a
    /// 512px thumbnail into a converted file would be silent quality loss. The
    /// source file is necessarily online during a conversion, so re-reading it
    /// costs nothing a conversion wasn't already paying.
    ///
    /// Returns the asset unchanged when its data is already present or the
    /// source no longer resolves any artwork (callers then convert without
    /// re-embedding, as they did before).
    public func hydrated(_ asset: ArtworkAsset, trackURL: URL) async -> ArtworkAsset {
        guard asset.data.isEmpty else { return asset }
        if let cached = cachedData(for: asset.hash) {
            return sharingBytes(asset, cached)
        }
        guard let resolved = await resolveArtwork(trackURL: trackURL) else { return asset }
        return resolved
    }

    public func generateThumbnail(artworkHash: String, size: CGSize) -> NSImage? {
        let cacheKey = "\(artworkHash)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let data = dataForHash(artworkHash),
              let image = NSImage(data: data),
              let thumbnail = renderThumbnail(image: image, size: size)
        else {
            return nil
        }

        let cost = Int(size.width * size.height * 4)   // ~RGBA bytes, relative weight
        thumbnailCache.setObject(thumbnail, forKey: cacheKey, cost: cost)
        return thumbnail
    }

    /// Off-main thumbnail decode (ImageIO), cached by hash+size. Unlike
    /// `generateThumbnail` it decodes/downscales on a background task instead of
    /// the main-thread `lockFocus` path, so scrolling a gallery stays smooth.
    public func thumbnailAsync(artworkHash: String, maxPixel: Int) async -> NSImage? {
        let cacheKey = "\(artworkHash)-t\(maxPixel)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }
        guard let data = dataForHash(artworkHash) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UncheckedSendableBox<NSImage?> in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UncheckedSendableBox(nil) }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UncheckedSendableBox(nil) }
            return UncheckedSendableBox(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }.value.value
        if let image {
            thumbnailCache.setObject(image, forKey: cacheKey, cost: maxPixel * maxPixel * 4)
        }
        return image
    }

    public func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
        try prepareCompatibleArtwork(asset: asset, profile: profile, maxDimension: nil)
    }

    public func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile, maxDimension: Int?) throws -> ArtworkAsset {
        let resizedDimension = maxDimension.map { max(120, $0) }
        guard profile == .ipodLegacySafe || resizedDimension != nil else {
            return asset
        }

        let memoKey = "\(asset.hash)|\(profile.rawValue)|\(resizedDimension ?? 0)" as NSString
        if let cached = preparedArtworkCache.object(forKey: memoKey) {
            return cached.asset
        }

        guard let image = NSImage(data: asset.data) else {
            throw ArtworkServiceError.couldNotDecodeImage
        }

        let targetDimension = CGFloat(resizedDimension ?? 600)
        let resized = resize(image: image, maxDimension: targetDimension)

        let chosenData: Data?
        if profile == .ipodLegacySafe {
            var compression: CGFloat = 0.90
            var candidate: Data?
            while compression >= 0.35 {
                if let data = jpegData(from: resized, compression: compression), data.count <= 300_000 {
                    candidate = data
                    break
                }
                compression -= 0.08
            }
            if candidate == nil {
                candidate = jpegData(from: resized, compression: 0.30)
            }
            chosenData = candidate
        } else {
            chosenData = jpegData(from: resized, compression: 0.92)
        }

        guard let compatibleData = chosenData,
              let validatedImage = NSImage(data: compatibleData)
        else {
            throw ArtworkServiceError.couldNotEncodeCompatibleJPEG
        }

        let compatible = ArtworkAsset(
            source: asset.source,
            hash: Self.sha256Hex(for: compatibleData),
            dimensions: ArtworkDimensions(
                width: Int(validatedImage.size.width.rounded()),
                height: Int(validatedImage.size.height.rounded())
            ),
            data: compatibleData
        )

        storeData(compatible.data, for: compatible.hash)
        preparedArtworkCache.setObject(PreparedArtworkBox(compatible), forKey: memoKey, cost: compatible.data.count)
        return compatible
    }

    private func embeddedArtwork(for trackURL: URL, preloadedMetadata: [AVMetadataItem]?) async -> ArtworkAsset? {
        if let preloadedMetadata {
            guard let data = await Self.firstArtworkData(in: preloadedMetadata) else {
                return nil
            }
            return artworkAsset(from: data, source: .embedded)
        }

        let asset = AVURLAsset(url: trackURL)

        if let commonMetadata = try? await asset.load(.commonMetadata),
           let data = await Self.firstArtworkData(in: commonMetadata),
           let artwork = artworkAsset(from: data, source: .embedded) {
            return artwork
        }

        let metadataFormats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in metadataFormats {
            guard let metadata = try? await asset.loadMetadata(for: format) else {
                continue
            }

            if let data = await Self.firstArtworkData(in: metadata),
               let artwork = artworkAsset(from: data, source: .embedded) {
                return artwork
            }
        }

        return nil
    }

    private func memoizedFolderArtwork(for trackURL: URL) -> ArtworkAsset? {
        let folderPath = trackURL.deletingLastPathComponent().path
        // ponytail: lock held across the disk probe so concurrent tracks in one
        // folder read the cover exactly once; the probe is tiny next to each
        // track's ffprobe spawn. Per-folder locks if this ever contends.
        folderMemoLock.lock()
        defer { folderMemoLock.unlock() }
        if let memoized = folderArtworkMemo[folderPath] {
            return memoized
        }
        let artwork = folderArtwork(for: trackURL)
        folderArtworkMemo[folderPath] = artwork
        return artwork
    }

    private func folderArtwork(for trackURL: URL) -> ArtworkAsset? {
        let folderURL = trackURL.deletingLastPathComponent()
        let candidates = [
            "cover.jpg", "cover.jpeg", "cover.png",
            "folder.jpg", "folder.jpeg", "folder.png",
            "front.jpg", "front.jpeg", "front.png"
        ]

        let subfolders = [
            "",
            "Artwork",
            "artwork",
            "Art",
            "art",
            "Covers",
            "covers"
        ]

        for subfolder in subfolders {
            let baseFolder = subfolder.isEmpty ? folderURL : folderURL.appendingPathComponent(subfolder)
            for name in candidates {
                let url = baseFolder.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path),
                   let data = try? Data(contentsOf: url),
                   let artwork = artworkAsset(from: data, source: .folderImage) {
                    return artwork
                }
            }
        }

        guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let prefixMatches = files
            .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" || $0.pathExtension.lowercased() == "png" }
            .filter { $0.lastPathComponent.lowercased().hasPrefix("albumart") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in prefixMatches {
            if let data = try? Data(contentsOf: url),
               let artwork = artworkAsset(from: data, source: .folderImage) {
                return artwork
            }
        }

        return nil
    }

    private func artworkAsset(from data: Data, source: ArtworkSource) -> ArtworkAsset? {
        guard let image = NSImage(data: data) else {
            return nil
        }

        return ArtworkAsset(
            source: source,
            hash: Self.sha256Hex(for: data),
            dimensions: ArtworkDimensions(
                width: Int(image.size.width.rounded()),
                height: Int(image.size.height.rounded())
            ),
            data: data
        )
    }

    private static func firstArtworkData(in metadataItems: [AVMetadataItem]) async -> Data? {
        for item in metadataItems {
            if item.commonKey?.rawValue == "artwork" {
                if let data = try? await item.load(.dataValue) {
                    return data
                }

                do {
                    let loadedValue = try await item.load(.value)
                    if let data = loadedValue as? Data {
                        return data
                    }
                    if let data = loadedValue as? NSData {
                        return data as Data
                    }
                } catch {
                    // Ignore failed metadata values and continue scanning.
                }
            }

            if let identifier = item.identifier?.rawValue.lowercased(),
               identifier.contains("covr") || identifier.contains("apic") {
                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        }

        return nil
    }

    private func renderThumbnail(image: NSImage, size: CGSize) -> NSImage? {
        let output = NSImage(size: size)
        output.lockFocus()
        defer { output.unlockFocus() }

        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        image.draw(in: drawRect)
        return output
    }

    private func resize(image: NSImage, maxDimension: CGFloat) -> NSImage {
        let sourceSize = image.size
        guard sourceSize.width > maxDimension || sourceSize.height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / sourceSize.width, maxDimension / sourceSize.height)
        let resizedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let output = NSImage(size: resizedSize)

        output.lockFocus()
        defer { output.unlockFocus() }

        image.draw(in: NSRect(origin: .zero, size: resizedSize))
        return output
    }

    private func jpegData(from image: NSImage, compression: CGFloat) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compression,
                .progressive: false
            ]
        )
    }

    /// Caches `data` under `hash` and returns the *canonical* buffer for that
    /// hash — the already-cached instance when there is one.
    ///
    /// Every track carries its cover's full-resolution bytes in
    /// `ArtworkAsset.data`, and an album's tracks each embed the same JPEG. Handing
    /// each track its own freshly-read copy retained one cover per *track*: a 644-track
    /// scan held 299 MB of art for 41 distinct covers (9.7 copies each). Returning
    /// the shared buffer makes the duplicates free — `Data` is copy-on-write.
    ///
    /// ponytail: the miss-then-set is deliberately unsynchronized. The scan resolves
    /// tracks concurrently, so two threads can both miss and both store — but the key
    /// is a content hash, so the bytes are identical and the loser is just one extra
    /// copy. A lock here would serialize every artwork read to save nothing.
    @discardableResult
    private func storeData(_ data: Data, for hash: String) -> Data {
        guard !data.isEmpty else { return data }
        if let existing = dataCache.object(forKey: hash as NSString) {
            return Data(referencing: existing)
        }
        let boxed = NSData(data: data)
        dataCache.setObject(boxed, forKey: hash as NSString, cost: data.count)
        store?.put(data, for: hash)
        return Data(referencing: boxed)
    }

    /// Wrap the cached bytes without copying them.
    ///
    /// The cache must hold a *genuine* `NSData` (hence `NSData(data:)` on the way
    /// in): bridging a Swift `Data` with `as NSData` produces a wrapper that copies
    /// the whole buffer back out on every single read — measured, so every cover
    /// lookup was cloning a full-resolution JPEG.
    private func cachedData(for hash: String) -> Data? {
        dataCache.object(forKey: hash as NSString).map { Data(referencing: $0) }
    }

    /// The same asset pointing at `data` instead of its own copy of the bytes.
    private func sharingBytes(_ asset: ArtworkAsset, _ data: Data) -> ArtworkAsset {
        ArtworkAsset(
            source: asset.source,
            hash: asset.hash,
            dimensions: asset.dimensions,
            data: data
        )
    }

    private func dataForHash(_ hash: String) -> Data? {
        if let cached = cachedData(for: hash) {
            return cached
        }
        // Fall back to the on-disk store (survives relaunch / offline drives),
        // then warm the in-memory cache for subsequent thumbnail renders.
        guard let data = store?.data(for: hash) else { return nil }
        let boxed = NSData(data: data)
        dataCache.setObject(boxed, forKey: hash as NSString, cost: data.count)
        return Data(referencing: boxed)
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}
