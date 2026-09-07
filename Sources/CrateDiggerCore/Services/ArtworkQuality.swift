import Foundation
import ImageIO

/// Whether an album's cover is good enough to keep, and whether a replacement
/// would actually be an improvement.
///
/// This is the decidable half of the "fix my library's artwork" pass: given the
/// sizes of what an album already has, does it need help, and is the candidate
/// better? Keeping it here means the batch pass can be reasoned about (and
/// tested) without a network or a library.
public enum ArtworkQuality {
    /// Below this longest edge a cover is a thumbnail, not artwork: it shows as
    /// a wall of pixels the moment anything displays it larger than a row.
    public static let minimumLongEdge = 500

    public enum Verdict: String, Sendable, Equatable {
        /// Nothing at all — no embedded tag image, no file in the folder.
        case missing
        /// Something, but too small to look at.
        case lowResolution
        /// Leave it alone.
        case adequate

        public var needsWork: Bool { self != .adequate }
    }

    /// `longEdges` is every cover the album has, measured on its longest side:
    /// the embedded tag image, a folder `cover.jpg`, a booklet front. The best
    /// one decides — an album with a 1400 px cover.jpg isn't "low res" because
    /// its tags also carry a 300 px thumbnail.
    public static func verdict(longEdges: [Int],
                               threshold: Int = minimumLongEdge) -> Verdict {
        let best = longEdges.filter { $0 > 0 }.max()
        guard let best else { return .missing }
        return best < threshold ? .lowResolution : .adequate
    }

    /// True when `candidate` is worth writing over `current`.
    ///
    /// The batch pass has to be able to say no: iTunes will happily answer a
    /// query with a 300 px thumbnail, and replacing a 480 px cover with it
    /// would be a downgrade dressed up as a repair. An album with nothing at
    /// all takes whatever it can get.
    public static func isUpgrade(from current: Int?, to candidate: Int) -> Bool {
        guard let current, current > 0 else { return candidate > 0 }
        return candidate > current
    }

    /// The pixel size of an image file, read from its header only — no decode,
    /// so this is cheap enough to run across a whole library.
    public static func pixelSize(ofImageAt url: URL) -> ArtworkDimensions? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return ArtworkDimensions(width: width, height: height)
    }
}

public extension ArtworkDimensions {
    var longEdge: Int { max(width, height) }
}
