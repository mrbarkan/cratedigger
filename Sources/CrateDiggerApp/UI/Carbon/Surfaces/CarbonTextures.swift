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

    /// A print dot screen: one dot per 6pt cell. Drawn in `.multiply`, so it
    /// bites into lit pixels and leaves unlit glass alone — a dark screen
    /// stays dark, the type breaks into dots.
    static let halftone: NSImage = dotTile(cell: 6, radius: 1.7)

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

    private static func dotTile(cell: Int, radius: CGFloat) -> NSImage {
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
                bytes[i + 3] = UInt8(coverage * 255)   // black at `coverage` alpha
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

    /// Film grain over the whole surface (interface effect: `effects.grain`).
    ///
    /// Two layers, and both are needed: `.plusLighter` adds each grain's alpha
    /// absolutely, then a flat `.plusDarker` veil subtracts the *average* of
    /// that back off. Without the veil the grain only ever brightens, and a
    /// dark console picks up a visible fog long before the texture reads.
    @ViewBuilder
    func carbonGrain(_ amount: Double) -> some View {
        if amount > 0 {
            compositingGroup()
                .overlay(
                    Image(nsImage: CarbonTexture.grain)
                        .resizable(resizingMode: .tile)
                        .blendMode(.plusLighter)
                        .opacity(amount)
                        .allowsHitTesting(false)
                )
                .overlay(
                    Color.black
                        .opacity(amount * CarbonTexture.grainStrength / 2)
                        .blendMode(.plusDarker)
                        .allowsHitTesting(false)
                )
        } else {
            self
        }
    }

    /// Lens-style corner falloff (interface effect: `effects.vignette`).
    /// An `EllipticalGradient` rather than a `RadialGradient` in a
    /// `GeometryReader`: it already sizes itself to the view, so the window
    /// can resize without a layout pass computing radii.
    @ViewBuilder
    func carbonVignette(_ amount: Double) -> some View {
        if amount > 0 {
            overlay(
                // The radius fractions matter more than the colours here. Left
                // at their defaults the gradient ends at the *edge midpoints*,
                // which puts every corner — a large slice of a wide window —
                // past the last stop and at full strength: not a vignette, a
                // dimmer. Ending at 0.78 pushes the ellipse out past the edges,
                // so the corners land near the dark end and the edges stay
                // barely touched.
                EllipticalGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(amount * 0.35), location: 0.6),
                        .init(color: .black.opacity(amount), location: 1)
                    ],
                    center: .center,
                    startRadiusFraction: 0.4,
                    endRadiusFraction: 0.78
                )
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }

    /// A diagonal reflection across glass (display effect: `effects.oledGlare`).
    /// Screen blend so it *adds* light like a real reflection rather than
    /// washing the panel out.
    @ViewBuilder
    func carbonGlare(_ amount: Double) -> some View {
        if amount > 0 {
            overlay(
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
            )
        } else {
            self
        }
    }

    /// Print dot screen (display effect: `effects.oledHalftone`).
    @ViewBuilder
    func carbonHalftone(_ amount: Double) -> some View {
        if amount > 0 {
            compositingGroup()
                .overlay(
                    Image(nsImage: CarbonTexture.halftone)
                        .resizable(resizingMode: .tile)
                        .blendMode(.multiply)
                        .opacity(amount)
                        .allowsHitTesting(false)
                )
        } else {
            self
        }
    }
}
