import AppKit
import SwiftUI

/// The overlay textures — grain and the halftone dot screen.
///
/// Each is generated **once** into a small tile and then tiled across whatever
/// it covers. Never a live `Canvas`, never a `Material`: anything that redraws
/// per frame at window size is what put this app at ~60% idle GPU before the
/// Materials came out, and a texture that never changes has no business being
/// redrawn. A tile is one upload and then nothing.
///
/// Procedural rather than shipped PNGs on purpose — no bundle weight, no
/// licence attached to a downloaded pack, and the tiles are generated at 2×
/// so they stay crisp on a Retina panel.
enum CarbonTexture {

    /// White speckles at random alpha, added with `.plusLighter` and then
    /// levelled back down by `grainFloor` — see `carbonGrain`. Absolute, not
    /// proportional: every grain moves its pixel by the same amount whatever
    /// it lands on.
    ///
    /// Two earlier builds were measured and thrown out. Mid-grey noise in
    /// `.overlay` blend — the way a grain layer works over a photograph —
    /// scales with the base, and against this chassis (luminance ≈ 6%) even
    /// full opacity moved a flat panel's spread from ±1 to ±3 of 255. Two-sided
    /// black-and-white noise in normal blend was visible but *lifted* the panel
    /// 16 → 19 of 255, because on a near-black surface the dark half has
    /// nowhere to go: grain that only brightens is fog.
    ///
    /// Generated at 1× on purpose, unlike the dot screen: at 2× each grain is
    /// a single device pixel, which reads as sensor noise. One grain per
    /// *point* is the size film actually looks like.
    static let grain: NSImage = noiseTile(side: 128, strength: grainStrength)

    /// The heaviest alpha any one grain gets. The mean is half of it, which is
    /// exactly what `carbonGrain` subtracts back.
    static let grainStrength: Double = 0.5

    /// A print dot screen: one dot per 6pt cell, in both polarities.
    ///
    /// Ink is only ink against a pale ground. On dark glass with lit type the
    /// dots have to be *dark* and multiply, so they bite into the type; on a
    /// pale panel with dark type — an iPod or calculator screen, which several
    /// presets and plenty of user themes are — that same dark dot dims the
    /// background and leaves the type alone, which looks like nothing
    /// happened. `carbonHalftone` picks by the glass, not by preference.
    /// A 3pt cell. Coarser screens were tried and measured: at an 8pt cell the
    /// dots are wider than the strokes of 7.5–13pt readout type, so nearly
    /// every stroke falls in a gap and a rail of labels barely moves (-3% of
    /// lit luminance). A dot screen has to be finer than the type it prints.
    static let halftoneDark: NSImage = dotTile(cell: 3, radius: 1.05, white: false)
    static let halftoneLight: NSImage = dotTile(cell: 3, radius: 1.05, white: true)

    // MARK: - Tiles

    private static func noiseTile(side: Int, strength: Double) -> NSImage {
        let pixels = side
        let bytesPerRow = pixels * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        var generator = SystemRandomNumberGenerator()
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = UInt8(Double.random(in: 0...strength, using: &generator) * 255)
            // White, premultiplied: (a, a, a, a).
            bytes[i] = alpha
            bytes[i + 1] = alpha
            bytes[i + 2] = alpha
            bytes[i + 3] = alpha
        }
        return image(from: bytes, pixels: pixels, bytesPerRow: bytesPerRow, points: side)
    }

    private static func dotTile(cell: Int, radius: CGFloat, white: Bool) -> NSImage {
        let scale = 2
        let pixels = cell * scale
        let bytesPerRow = pixels * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixels)

        // Drawn by hand rather than through CGContext: one dot in one tiny
        // tile, and a distance test is shorter than setting up a context,
        // stroking a path and reading the buffer back out.
        let center = CGFloat(pixels) / 2
        let r = radius * CGFloat(scale)
        for y in 0..<pixels {
            for x in 0..<pixels {
                let dx = CGFloat(x) + 0.5 - center
                let dy = CGFloat(y) + 0.5 - center
                // Coverage across the last pixel of the edge, so the dot has a
                // soft rim instead of a staircase.
                let coverage = min(max(r - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
                let i = y * bytesPerRow + x * 4
                let alpha = UInt8(coverage * 255)
                if white {
                    bytes[i] = alpha
                    bytes[i + 1] = alpha
                    bytes[i + 2] = alpha
                }
                bytes[i + 3] = alpha
            }
        }
        return image(from: bytes, pixels: pixels, bytesPerRow: bytesPerRow, points: cell)
    }

    /// Wraps a premultiplied RGBA buffer as an `NSImage` sized in *points*, so
    /// `.resizable(resizingMode: .tile)` repeats it at the size intended
    /// rather than at whatever the pixel count happens to be.
    private static func image(from bytes: [UInt8], pixels: Int, bytesPerRow: Int, points: Int) -> NSImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return NSImage(size: NSSize(width: points, height: points)) }
        return NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
    }
}

// MARK: - Effect modifiers

/// Every one of these is a **no-op at 0** — not an overlay drawing nothing, but
/// the bare view, with no compositing group and no extra layer. They're applied
/// unconditionally at the top of the chassis and the display, so an unused
/// effect has to cost exactly nothing.
extension View {

    /// Texture grain over the surface (interface effect: `effects.grain`).
    ///
    /// Two layers, and both are needed: `.plusLighter` adds each grain's alpha
    /// absolutely, then a flat `.plusDarker` veil subtracts the *average* of
    /// that back off. Without the veil the grain only ever brightens, and a
    /// dark console picks up a visible fog long before the texture reads.
    ///
    /// Both layers are masked around anything that called `grainFree()` — the
    /// display glass. Grain is the tooth of the console's own material, and a
    /// screen sitting behind glass doesn't have it; textured along with the
    /// chassis, the display reads as a sticker printed on the front panel.
    @ViewBuilder
    func carbonGrain(_ amount: Double) -> some View {
        if amount > 0 {
            compositingGroup()
                .overlayPreferenceValue(GrainFreeKey.self) { holes in
                    GeometryReader { proxy in
                        let mask = GrainMask(holes: holes.map { (proxy[$0.bounds], $0.cornerRadius) })
                        ZStack {
                            Image(nsImage: CarbonTexture.grain)
                                .interpolation(.none)
                                .resizable(resizingMode: .tile)
                                .mask(mask)
                                .blendMode(.plusLighter)
                                .opacity(amount)
                            Color.black
                                .mask(mask)
                                .opacity(amount * CarbonTexture.grainStrength / 2)
                                .blendMode(.plusDarker)
                        }
                    }
                    .allowsHitTesting(false)
                }
        } else {
            self
        }
    }

    /// Keeps the interface grain off this view — see `carbonGrain`. The rect is
    /// reported to whichever `carbonGrain` is above it, so the caller doesn't
    /// have to know where in the tree that is.
    func grainFree(cornerRadius: CGFloat) -> some View {
        anchorPreference(key: GrainFreeKey.self, value: .bounds) {
            [GrainFreeRegion(bounds: $0, cornerRadius: cornerRadius)]
        }
    }

    /// A diagonal reflection across glass (display effect: `effects.oledGlare`).
    /// Screen blend so it *adds* light like a real reflection rather than
    /// washing the panel out — and grouped with what it blends against, for
    /// the reason spelled out in `carbonHalftone`.
    @ViewBuilder
    func carbonGlare(_ amount: Double) -> some View {
        if amount > 0 {
            ZStack {
                self
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(amount), location: 0),
                        .init(color: .white.opacity(amount * 0.55), location: 0.12),
                        .init(color: .white.opacity(amount * 0.10), location: 0.30),
                        .init(color: .clear, location: 0.52)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
            }
            .compositingGroup()
        } else {
            self
        }
    }

    /// Print dot screen (display effect: `effects.oledHalftone`).
    ///
    /// `panel` is the glass this lands on. Its luminance picks the ink: dark
    /// dots multiplied into a lit screen, light dots added onto a pale one.
    /// Passing the colour rather than a flag keeps the decision in one place —
    /// every caller would otherwise have to remember the same luminance test.
    @ViewBuilder
    func carbonHalftone(_ amount: Double, on panel: Color) -> some View {
        if amount > 0 {
            let pale = panel.themeLuminance > 0.5
            // The blend has to be *inside* a group that also holds what it
            // blends with. `self.compositingGroup().overlay(dots.blendMode())`
            // reads the same and isn't: the dots end up blending against
            // whatever the enclosing context happens to be, and on the OLED —
            // clipped, and inside the display's own compositing group — that
            // resolved to no visible change at all.
            ZStack {
                self
                Image(nsImage: pale ? CarbonTexture.halftoneLight : CarbonTexture.halftoneDark)
                    .interpolation(.none)
                    .resizable(resizingMode: .tile)
                    .blendMode(pale ? .plusLighter : .multiply)
                    .opacity(amount)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
        } else {
            self
        }
    }
}


// MARK: - Grain holes

/// One region the interface grain skips, in the coordinate space of the view
/// that draws the grain.
struct GrainFreeRegion: Equatable {
    let bounds: Anchor<CGRect>
    let cornerRadius: CGFloat
}

struct GrainFreeKey: PreferenceKey {
    static let defaultValue: [GrainFreeRegion] = []
    static func reduce(value: inout [GrainFreeRegion], nextValue: () -> [GrainFreeRegion]) {
        value.append(contentsOf: nextValue())
    }
}

/// Opaque everywhere except the reported regions, which are punched clear so
/// the grain layers above them draw nothing at all.
private struct GrainMask: View {
    let holes: [(rect: CGRect, cornerRadius: CGFloat)]

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(
                ZStack {
                    ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                        RoundedRectangle(cornerRadius: hole.cornerRadius, style: .continuous)
                            .fill(Color.black)
                            .frame(width: hole.rect.width, height: hole.rect.height)
                            .position(x: hole.rect.midX, y: hole.rect.midY)
                            .blendMode(.destinationOut)
                    }
                }
            )
            .compositingGroup()
    }
}
