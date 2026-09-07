import AppKit
import CrateDiggerCore

/// Turns a crop into the file the theme ships: the source image drawn where
/// `LogoCropPlanner` puts it, on a transparent bitmap the shape of the header
/// slot. The editor's viewport and 1:1 preview draw from the same planner, so
/// this is exactly what they showed.
enum LogoRenderer {
    /// Pixels per slot point. Eight is more than a 3x display asks of a
    /// 110pt strip and keeps a vector source crisp when it's enlarged.
    static let exportScale: CGFloat = 8

    static func png(_ image: NSImage, slot: CGSize, crop: LogoCrop) -> Data? {
        let width = Int((slot.width * exportScale).rounded())
        let height = Int((slot.height * exportScale).rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        // The planner's frame hangs from the top-left; the bitmap grows from
        // the bottom-left.
        let rect = LogoCropPlanner.imageRect(image: image.size, in: slot, crop: crop)
        let flipped = CGRect(x: rect.minX, y: slot.height - rect.maxY, width: rect.width, height: rect.height)
        image.draw(
            in: flipped.applying(CGAffineTransform(scaleX: exportScale, y: exportScale)),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
