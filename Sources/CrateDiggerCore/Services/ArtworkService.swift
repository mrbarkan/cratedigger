import AppKit
import AVFoundation
import CryptoKit
import Foundation

public protocol ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset
}

public enum ArtworkServiceError: Error {
    case couldNotDecodeImage
    case couldNotEncodeCompatibleJPEG
}

public final class ArtworkService: ArtworkPreparing {
    private let fileManager: FileManager
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.cratedigger.artwork.cache", attributes: .concurrent)
    private var dataByHash: [String: Data] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        thumbnailCache.countLimit = 512
    }

    public func resolveArtwork(trackURL: URL) -> ArtworkAsset? {
        if let embedded = embeddedArtwork(for: trackURL) {
            storeData(embedded.data, for: embedded.hash)
            return embedded
        }

        if let folder = folderArtwork(for: trackURL) {
            storeData(folder.data, for: folder.hash)
            return folder
        }

        return nil
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

        thumbnailCache.setObject(thumbnail, forKey: cacheKey)
        return thumbnail
    }

    public func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
        guard profile == .ipodLegacySafe else {
            return asset
        }

        guard let image = NSImage(data: asset.data) else {
            throw ArtworkServiceError.couldNotDecodeImage
        }

        let resized = resize(image: image, maxDimension: 600)

        var compression: CGFloat = 0.90
        var chosenData: Data?
        while compression >= 0.35 {
            if let data = jpegData(from: resized, compression: compression), data.count <= 300_000 {
                chosenData = data
                break
            }
            compression -= 0.08
        }

        if chosenData == nil {
            chosenData = jpegData(from: resized, compression: 0.30)
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
        return compatible
    }

    private func embeddedArtwork(for trackURL: URL) -> ArtworkAsset? {
        let asset = AVURLAsset(url: trackURL)

        if let data = Self.firstArtworkData(in: asset.commonMetadata),
           let artwork = artworkAsset(from: data, source: .embedded) {
            return artwork
        }

        for format in asset.availableMetadataFormats {
            let metadata = asset.metadata(forFormat: format)
            if let data = Self.firstArtworkData(in: metadata),
               let artwork = artworkAsset(from: data, source: .embedded) {
                return artwork
            }
        }

        return nil
    }

    private func folderArtwork(for trackURL: URL) -> ArtworkAsset? {
        let folderURL = trackURL.deletingLastPathComponent()
        let candidates = [
            "cover.jpg", "cover.jpeg", "cover.png",
            "folder.jpg", "folder.jpeg", "folder.png",
            "front.jpg", "front.jpeg", "front.png"
        ]

        for name in candidates {
            let url = folderURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let artwork = artworkAsset(from: data, source: .folderImage) {
                return artwork
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

    private static func firstArtworkData(in metadataItems: [AVMetadataItem]) -> Data? {
        for item in metadataItems {
            if item.commonKey?.rawValue == "artwork" {
                if let data = item.dataValue {
                    return data
                }

                if let data = item.value as? Data {
                    return data
                }

                if let data = item.value as? NSData {
                    return data as Data
                }
            }

            if let identifier = item.identifier?.rawValue.lowercased(),
               identifier.contains("covr") || identifier.contains("apic") {
                if let data = item.dataValue {
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

    private func storeData(_ data: Data, for hash: String) {
        cacheQueue.async(flags: .barrier) {
            self.dataByHash[hash] = data
        }
    }

    private func dataForHash(_ hash: String) -> Data? {
        cacheQueue.sync {
            dataByHash[hash]
        }
    }

    private static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
