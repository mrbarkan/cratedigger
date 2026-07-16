import CoreGraphics
import Foundation
import ImageIO

/// Downscale-and-encode for the on-disk artwork cache.
///
/// The cache exists to draw covers — for cold launches and offline source
/// drives — not to be a second copy of the library's art. Full-resolution
/// covers (a few MB each) are therefore never written to disk by the app;
/// they're squeezed through here first. Canonical art stays where it belongs:
/// embedded in the audio file, or as `cover.jpg` in the album folder.
public enum ArtworkThumbnail {
    /// Comfortably above the largest on-screen use (the inspector poster), so a
    /// thumbnail never looks soft where it's actually shown.
    public static let maxPixel = 512

    /// Downscale `data` to a JPEG no larger than `maxPixel` on its long edge.
    ///
    /// Returns `nil` when the bytes aren't a decodable image — callers decide
    /// what that means for them. Already-small images are returned unchanged
    /// rather than re-encoded, since re-encoding one can cost *more* bytes than
    /// it saves.
    public static func encode(_ data: Data, maxPixel: Int = ArtworkThumbnail.maxPixel, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }

        let encoded = output as Data
        // A small PNG/JPEG can round-trip *bigger* than it started; keep the
        // original in that case — the point is to spend less disk, not more.
        return encoded.count < data.count ? encoded : data
    }
}
