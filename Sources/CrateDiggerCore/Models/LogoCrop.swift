import Foundation

/// How a source image sits in the header's logo slot: how much it's enlarged
/// and where it's been dragged. Frame-relative, so the same crop renders
/// identically in the editor's viewport, the 1:1 preview and the exported
/// bitmap — they only differ in scale.
public struct LogoCrop: Equatable, Sendable {
    /// 1 fits the whole image inside the frame (letterboxed); above that the
    /// image grows about its centre, below it shrinks to a mark that needn't
    /// fill the strip.
    public var zoom: CGFloat
    /// Pan from centred, as fractions of the frame's width and height, so
    /// `0.5` is always "half a slot" whatever size the slot is drawn at.
    public var offset: CGSize

    public static let zoomRange: ClosedRange<CGFloat> = 0.25...6

    public init(zoom: CGFloat = 1, offset: CGSize = .zero) {
        self.zoom = zoom
        self.offset = offset
    }

    public static let fit = LogoCrop()
}

/// The geometry behind the logo cropper. One function, `imageRect`, decides
/// where the image lands; everything that draws the crop asks it, which is
/// what makes the preview honest.
public enum LogoCropPlanner {
    /// The scale that fits the whole image inside the frame.
    public static func fitScale(image: CGSize, in frame: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(frame.width / image.width, frame.height / image.height)
    }

    /// The zoom at which the image covers the frame with nothing showing
    /// around it, relative to `fitScale`.
    public static func fillZoom(image: CGSize, in frame: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        let fill = max(frame.width / image.width, frame.height / image.height)
        return fill / fitScale(image: image, in: frame)
    }

    /// Where the image draws inside a frame whose origin is its top-left
    /// corner. The offset is clamped so an enlarged image never uncovers the
    /// frame and a shrunken one never leaves it.
    public static func imageRect(image: CGSize, in frame: CGSize, crop: LogoCrop) -> CGRect {
        let crop = clamped(crop, image: image, in: frame)
        let size = displayedSize(image: image, in: frame, zoom: crop.zoom)
        return CGRect(
            x: (frame.width - size.width) / 2 + crop.offset.width * frame.width,
            y: (frame.height - size.height) / 2 + crop.offset.height * frame.height,
            width: size.width,
            height: size.height
        )
    }

    /// The crop with its zoom in range and its offset kept inside the
    /// bounds `imageRect` enforces, so a drag stops where the image would
    /// start to look wrong rather than snapping back on release.
    public static func clamped(_ crop: LogoCrop, image: CGSize, in frame: CGSize) -> LogoCrop {
        var result = crop
        result.zoom = min(max(crop.zoom, LogoCrop.zoomRange.lowerBound), LogoCrop.zoomRange.upperBound)
        let size = displayedSize(image: image, in: frame, zoom: result.zoom)

        // Enlarged past the frame: the image may slide only as far as its
        // edge reaching the frame's edge. Smaller than the frame: only as far
        // as its edge reaching the frame's edge from the inside. Both are the
        // same bound, half the difference in size, with the sign flipped.
        func limit(_ imageSide: CGFloat, _ frameSide: CGFloat) -> CGFloat {
            guard frameSide > 0 else { return 0 }
            return abs(imageSide - frameSide) / 2 / frameSide
        }
        let limitX = limit(size.width, frame.width)
        let limitY = limit(size.height, frame.height)
        result.offset = CGSize(
            width: min(max(crop.offset.width, -limitX), limitX),
            height: min(max(crop.offset.height, -limitY), limitY)
        )
        return result
    }

    private static func displayedSize(image: CGSize, in frame: CGSize, zoom: CGFloat) -> CGSize {
        let scale = fitScale(image: image, in: frame) * zoom
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
