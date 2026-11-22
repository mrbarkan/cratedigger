import AppKit
import CrateDiggerCore
import SwiftUI

// The cover screen: the compact player's and the mini player's cover shown on
// a low-resolution LCD set into the shell, when the theme turns a look on
// (`CarbonTheme.coverScreenLook`). The maths is Core's (`CoverScreenLayout`,
// `CoverScreenRenderer`); this file turns a cover into that LCD picture and
// houses it. With no look none of it is used, and both players draw exactly
// what they drew before it existed.

// MARK: - What to draw

/// Everything the cover screen needs to know, fixed for one theme, one well
/// size and one backing scale. Equatable so it can be part of a `.task(id:)`
/// key: a theme edit or a move to a display of another scale changes it, and
/// the picture is re-rendered once.
struct CoverScreenSpec: Equatable {
    let look: CoverScreenLook
    /// The grid strength (the look's dial value).
    let strength: Double
    let layout: CoverScreenLayout
    /// The backing scale the layout was planned for.
    let scale: CGFloat
    /// The unlit panel's colour, sRGB.
    let unlit: RGB8

    struct RGB8: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    /// nil when the theme has no look, or when `side` is too small to hold a
    /// screen (`CoverScreenLayout.count == 0`); the caller then draws its
    /// plain cover, as it does today.
    init?(theme: CarbonTheme, side: CGFloat, scale: CGFloat) {
        guard let look = theme.coverScreenLook else { return nil }
        let layout = CoverScreenLayout.plan(side: Double(side), scale: Double(scale),
                                            pixelSize: theme.coverPixelSize)
        guard layout.count > 0 else { return nil }
        let surface = Self.rgb8(theme.oledSurface)
        let unlit = CoverScreenRenderer.unlitColor(r: surface.r, g: surface.g, b: surface.b)
        self.init(look: look, strength: theme.coverScreenStrength, layout: layout, scale: scale,
                  unlit: RGB8(r: unlit.0, g: unlit.1, b: unlit.2))
    }

    init(look: CoverScreenLook, strength: Double, layout: CoverScreenLayout, scale: CGFloat, unlit: RGB8) {
        self.look = look
        self.strength = strength
        self.layout = layout
        self.scale = scale
        self.unlit = unlit
    }

    /// The LCD's side in points: `lcdSide` device pixels at `scale`.
    var lcdPoints: CGFloat { CGFloat(layout.lcdSide) / scale }
    /// The bezel band on the top and left, in points.
    var bandPoints: CGFloat { CGFloat(layout.band) / scale }
    /// The side, in pixels, the cover is resampled to before the renderer:
    /// one pixel per LCD pixel, except the grid look, which keeps the sharp
    /// cover under its grid.
    var sourceSide: Int { look == .grid ? layout.lcdSide : layout.count }

    /// What a rendered picture depends on, beyond the cover itself.
    var renderKey: String {
        "\(look.rawValue)|\(strength)|\(layout.cell)x\(layout.count)"
    }

    var unlitColor: Color {
        Color(.sRGB, red: Double(unlit.r) / 255, green: Double(unlit.g) / 255, blue: Double(unlit.b) / 255)
    }

    private static func rgb8(_ color: Color) -> RGB8 {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return RGB8(r: 0, g: 0, b: 0) }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
        return RGB8(r: byte(srgb.redComponent), g: byte(srgb.greenComponent), b: byte(srgb.blueComponent))
    }
}

// MARK: - Making the picture

/// Turns a cover into the LCD picture. Pure CoreGraphics, safe off the main
/// thread; `NowPlayingCover` runs it in a detached task and caches the result.
enum CoverScreenImage {
    /// The cover on the screen, or nil if it could not be drawn or the task
    /// running it was cancelled (checked between stages and per row).
    static func render(_ cover: CGImage, spec: CoverScreenSpec) -> CGImage? {
        guard !Task.isCancelled, let source = resample(cover, side: spec.sourceSide),
              !Task.isCancelled else { return nil }
        return picture(from: source, spec: spec)
    }

    /// The unlit panel: a flat source through the same renderer, so its grid
    /// is the real grid.
    static func renderUnlit(spec: CoverScreenSpec) -> CGImage? {
        let source = CoverScreenRenderer.flatSource(r: spec.unlit.r, g: spec.unlit.g, b: spec.unlit.b,
                                                    count: spec.layout.count)
        // The grid look's source is `lcdSide` square; a flat colour is the
        // same at either resolution, so the pixel look stands in for it.
        let look: CoverScreenLook = spec.look == .grid ? .pixel : spec.look
        let pixels = CoverScreenRenderer.render(source: source, look: look, layout: spec.layout,
                                                gridStrength: spec.strength,
                                                isCancelled: { Task.isCancelled })
        return makeImage(rgba: pixels, side: spec.layout.lcdSide)
    }

    private static func picture(from source: [UInt8], spec: CoverScreenSpec) -> CGImage? {
        let pixels = CoverScreenRenderer.render(source: source, look: spec.look, layout: spec.layout,
                                                gridStrength: spec.strength,
                                                isCancelled: { Task.isCancelled })
        return makeImage(rgba: pixels, side: spec.layout.lcdSide)
    }

    /// The cover as `side * side` opaque RGBA8 sRGB, aspect-filled and
    /// centred, so a non-square cover is cropped the way the well crops it.
    /// The context is filled black first, so a transparent PNG comes out
    /// opaque (the renderer assumes it is).
    static func resample(_ image: CGImage, side: Int) -> [UInt8]? {
        guard side > 0, image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(bounds)
            context.interpolationQuality = .high
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let fill = max(CGFloat(side) / width, CGFloat(side) / height)
            let size = CGSize(width: width * fill, height: height * fill)
            let rect = CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                              width: size.width, height: size.height)
            context.draw(image, in: rect)
            return true
        }
        return drawn ? pixels : nil
    }

    /// Opaque sRGB, and `shouldInterpolate: false`, so nothing downstream is
    /// invited to smooth the grid.
    static func makeImage(rgba: [UInt8], side: Int) -> CGImage? {
        guard side > 0, rgba.count == side * side * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// The rendered pictures, shared by both players. Keyed by what the picture
/// shows (`NowPlayingCover`'s cover key: the track and its artwork hash, or
/// the stream and its thumbnail URL; plus the booklet front cover's identity
/// on disk) and `CoverScreenSpec.renderKey`; never by the `NSImage`'s
/// identity, since the loaders hand back a fresh image for the same art and a
/// freed image's identifier can be reused by another cover. Small: one
/// picture per track, and a fold back and forth only needs the last one.
enum CoverScreenCache {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 8
        return cache
    }()

    static func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    static func store(_ image: CGImage, forKey key: String) {
        cache.setObject(Entry(image), forKey: key as NSString)
    }
}

// MARK: - The housing

/// The screen's housing: a dark bezel band set into the shell, the LCD inset
/// in it at whole device pixels, the bezel's shadow falling on the glass from
/// the top and left, and a lip where the bezel meets the plastic.
///
/// It is set *into* the shell, so it has no drop shadow: a drop shadow is
/// what makes a screen float. It replaces `RecessedWell` (compact player) and
/// the sleeve (mini player) while a look is on.
struct CoverScreenBezel<Content: View>: View {
    @Environment(\.carbon) private var theme
    let spec: CoverScreenSpec
    /// The housing's own corner: the well's in the compact player, the art
    /// frame's in the mini player.
    let cornerRadius: CGFloat
    @ViewBuilder var content: () -> Content

    /// The LCD's own corner, small: a panel cut square with a slight radius.
    static var lcdCornerRadius: CGFloat { 2.5 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let lcd = RoundedRectangle(cornerRadius: Self.lcdCornerRadius, style: .continuous)
        GeometryReader { proxy in
            // The LCD has to start on a whole device pixel or every grid line
            // lands between two. The bezel's origin is a whole point at the
            // default geometry, but a theme's geometry dials can leave a
            // fraction; the snap moves the LCD (only) onto the device grid.
            let origin = proxy.frame(in: .global).origin
            let snapX = CGFloat(CoverScreenLayout.pixelSnap(origin: Double(origin.x), scale: Double(spec.scale)))
            let snapY = CGFloat(CoverScreenLayout.pixelSnap(origin: Double(origin.y), scale: Double(spec.scale)))
            ZStack(alignment: .topLeading) {
                shape
                    .fill(theme.oledStrokeInner)
                    .overlay(shape.fill(LinearGradient(colors: [.clear, .black.opacity(0.08)],
                                                       startPoint: .top, endPoint: .bottom)))
                // Not resizable and not in a drawing group: the picture is
                // drawn at its natural size, one image pixel per device pixel.
                content()
                    .frame(width: spec.lcdPoints, height: spec.lcdPoints, alignment: .topLeading)
                    .overlay(glassShadow)
                    .clipShape(lcd)
                    .offset(x: spec.bandPoints + snapX, y: spec.bandPoints + snapY)
            }
        }
        .overlay(lip(shape))
        // The housing is not shell: no grain or material over the bezel or
        // the glass. The lip, outside it, is shell and keeps it.
        .grainFree(shape: shape)
    }

    /// The bezel's shadow on the glass: the band stands proud of the LCD, so
    /// it shades the glass under its top edge and, more lightly, its left.
    private var glassShadow: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    /// Where the bezel meets the shell, 1 pt just outside it: in shadow along
    /// the top, catching the light along the bottom, as a cut-out in a
    /// moulded case does.
    private func lip(_ shape: RoundedRectangle) -> some View {
        let dark = Color.black.opacity(theme.isDark ? 0.75 : 0.45)
        let light = theme.isDark ? theme.chassisHi.opacity(0.5) : Color.white.opacity(0.85)
        return shape
            .inset(by: -0.5)
            .stroke(LinearGradient(stops: [
                .init(color: dark, location: 0),
                .init(color: dark.opacity(0.5), location: 0.45),
                .init(color: light.opacity(0.35), location: 0.6),
                .init(color: light, location: 1)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}
