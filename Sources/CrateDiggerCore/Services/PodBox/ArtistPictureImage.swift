import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a downloaded or picked image into the artist picture written to an
/// iPod: a 400 px square, sRGB, baseline JPEG with no metadata and at most
/// 100 KB. PodBox crops every picture square and caches it at 300 px and
/// smaller, so 400 px leaves headroom without costing the player time.
/// Anything that is not a usable portrait (too small, a banner, a header
/// claiming a giant size, unreadable or truncated bytes) gives nil.
public enum ArtistPictureImage {
    public static let edge = 400, minimumSource = 300, maximumBytes = 100 * 1024, maximumSourcePixels = 12_000
    /// Width times height the header may claim (50 megapixels): even a
    /// thumbnail decode of more can take a long time and a lot of memory.
    public static let maximumSourceArea = 50_000_000
    /// Bytes a source may have before anything reads it (32 MB). An artist
    /// photo is far smaller; a bigger file is not one.
    public static let maximumSourceBytes = 32 * 1024 * 1024
    /// The decode is a thumbnail of at most this many pixels on the long
    /// side, so a big source is never decoded in full.
    static let decodeLimit = 1_200
    /// Longest side over shortest side; beyond it the crop would lose the face.
    static let maximumAspect: CGFloat = 2
    /// JPEG qualities tried in order until the output fits.
    static let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45, 0.35]

    /// The square kept from an image of `size` (top-left origin): the
    /// largest centred square, except that a portrait keeps its full width
    /// with the square's top a third of the spare height down, where a face is.
    public static func cropRect(for size: CGSize) -> CGRect {
        let width = Int(size.width), height = Int(size.height)
        let side = min(width, height)
        if height > width {
            return CGRect(x: 0, y: (height - width) / 3, width: side, height: side)
        }
        return CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }

    public static func prepare(_ data: Data) -> Data? {
        prepare(data, reportedSize: nil)
    }

    /// `reportedSize` stands in for the size the header claims, so a test
    /// can check the giant-image refusal without making a giant image.
    static func prepare(_ data: Data, reportedSize: CGSize?) -> Data? {
        guard !data.isEmpty, data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              isWhole(data, type: CGImageSourceGetType(source) as String?),
              let size = reportedSize ?? headerSize(source),
              isAcceptable(size) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLimit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let square = decoded.cropping(to: cropRect(for: CGSize(width: decoded.width, height: decoded.height))),
              let drawn = draw(square) else { return nil }

        for quality in qualities {
            guard let jpeg = encode(drawn, quality: quality) else { return nil }
            if jpeg.count <= maximumBytes { return jpeg }
        }
        return nil
    }

    // MARK: - Private

    /// The pixel size the header claims, after its orientation is applied.
    /// Also read by `ArtistPhotoImage` for the artist profile photos.
    static func headerSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // EXIF orientations 5 to 8 turn the picture a quarter.
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private static func isAcceptable(_ size: CGSize) -> Bool {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return short >= CGFloat(minimumSource)
            && long <= CGFloat(maximumSourcePixels)
            && size.width * size.height <= CGFloat(maximumSourceArea)
            && long <= short * maximumAspect
    }

    /// The square scaled into an opaque sRGB 400 × 400, over white so a
    /// transparent area reads as paper rather than black.
    private static func draw(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: edge, height: edge)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// A baseline JPEG (progressive is never asked for). No metadata is
    /// passed, but ImageIO still writes small Exif and Photoshop segments
    /// of its own, so those are cut out afterwards.
    private static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return strippingMetadata(output as Data)
    }

    // MARK: - JPEG and container bytes

    /// The JPEG with every APP1 to APP15 and COM segment before the first
    /// scan removed (Exif, XMP, ICC, Photoshop, comments). APP0 (JFIF) and
    /// everything the decoder needs stay. nil when the header does not parse.
    static func strippingMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var kept: [UInt8] = [0xFF, 0xD8]
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return nil }
            if marker == 0xDA {
                kept += bytes[index...] // the scans and the end marker, as written
                return Data(kept)
            }
            let isMetadata = (0xE1...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata { kept += bytes[index..<(index + 2 + length)] }
            index += 2 + length
        }
        return nil
    }

    /// ImageIO reports a truncated file as complete and decodes it with a
    /// grey or garbage tail, so each accepted format is walked to its end
    /// here. A format this cannot check (HEIC, TIFF, ...) is refused.
    static func isWhole(_ data: Data, type: String?) -> Bool {
        let bytes = [UInt8](data)
        switch type {
        case UTType.jpeg.identifier: return jpegReachesItsEnd(bytes)
        case UTType.png.identifier: return pngReachesItsEnd(bytes)
        case UTType.webP.identifier:
            // RIFF: bytes 4..7 are the size of everything after them.
            guard bytes.count >= 12 else { return false }
            return Int(littleEndian32(bytes, at: 4)) + 8 <= bytes.count
        case UTType.bmp.identifier:
            // BITMAPFILEHEADER: bytes 2..5 are the file size.
            guard bytes.count >= 14 else { return false }
            return Int(littleEndian32(bytes, at: 2)) <= bytes.count
        case UTType.gif.identifier:
            return gifReachesItsEnd(bytes)
        default:
            return false
        }
    }

    /// Walks the header, colour tables and blocks to the trailer (0x3B).
    private static func gifReachesItsEnd(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 13, bytes.starts(with: Array("GIF".utf8)) else { return false }
        /// A colour table follows when bit 7 of `flags` is set: 3 × 2^(n+1) bytes.
        func tableSize(_ flags: UInt8) -> Int { flags & 0x80 == 0 ? 0 : 3 << (Int(flags & 0x07) + 1) }
        /// Skips data sub-blocks up to and past their zero terminator; nil when cut short.
        func skipSubBlocks(from start: Int) -> Int? {
            var index = start
            while index < bytes.count {
                let length = Int(bytes[index])
                index += 1
                if length == 0 { return index }
                index += length
            }
            return nil
        }
        var index = 13 + tableSize(bytes[10])
        while index < bytes.count {
            switch bytes[index] {
            case 0x3B:
                return true
            case 0x21: // extension: label, then sub-blocks
                guard let next = skipSubBlocks(from: index + 2) else { return false }
                index = next
            case 0x2C: // image: 9-byte descriptor, local table, LZW code size, sub-blocks
                guard index + 10 < bytes.count else { return false }
                let start = index + 10 + tableSize(bytes[index + 9]) + 1
                guard let next = skipSubBlocks(from: start) else { return false }
                index = next
            default:
                return false
            }
        }
        return false
    }

    /// Walks the segments and the entropy-coded scans to the end marker.
    private static func jpegReachesItsEnd(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var index = 2
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { return false }
            let marker = bytes[index + 1]
            switch marker {
            case 0xD9:
                return true
            case 0xFF:
                index += 1 // fill byte
                continue
            case 0x01, 0xD0...0xD7:
                index += 2 // markers without a length
                continue
            default:
                break
            }
            guard index + 3 < bytes.count else { return false }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return false }
            index += 2 + length
            if marker == 0xDA {
                // Entropy-coded data: a 0xFF is followed by 0x00 (stuffing) or
                // a restart marker; anything else is the next real marker.
                while index + 1 < bytes.count {
                    if bytes[index] == 0xFF, bytes[index + 1] != 0x00, !(0xD0...0xD7).contains(bytes[index + 1]) {
                        break
                    }
                    index += 1
                }
            }
        }
        return false
    }

    /// Walks the chunks to IEND.
    private static func pngReachesItsEnd(_ bytes: [UInt8]) -> Bool {
        var index = 8 // the signature
        while index + 8 <= bytes.count {
            let length = Int(bigEndian32(bytes, at: index))
            let type = bytes[(index + 4)..<(index + 8)]
            let end = index + 12 + length
            guard end <= bytes.count else { return false }
            if type.elementsEqual("IEND".utf8) { return true }
            index = end
        }
        return false
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * UInt32($1)) }
    }

    private static func bigEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[index + $1]) }
    }
}
