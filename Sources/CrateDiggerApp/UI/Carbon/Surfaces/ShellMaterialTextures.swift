import AppKit
import CrateDiggerCore
import SwiftUI

/// The tiles for the four shell materials: moulded plastic, brushed metal,
/// bead-blasted metal and carbon weave. Grain keeps its own tile in
/// `CarbonTexture`, untouched, so Carbon draws exactly what it always did.
///
/// The rule in `CarbonTexture` holds here too: each material is generated
/// **once**, the first time something draws it, into a tile that is then
/// only ever tiled. Nothing is redrawn while the app idles, while a window
/// resizes or while a fold travels.
///
/// Each material is a signed field (about ±1, light above zero, shade below)
/// split into a pair of tiles: the positive half as white premultiplied alpha,
/// added with `.plusLighter`, and the negative half as black alpha, taken away
/// with `.plusDarker` (grain's veil, with the field's own dark half in place
/// of a flat one). Absolute, not proportional: every texel moves its pixel by
/// the same amount whatever it lands on, which is why a material shows on a
/// near-black chassis and on a pale one alike.
///
/// Keep them translucent white and black. An opaque grey pair (`|f|` under
/// `.plusLighter`, `1 − |f|` under `.plusDarker`) composites to the same
/// pixels on screen, and was tried; but anything that flattens the tree with
/// blend modes treated as plain source-over then paints the console grey or,
/// with the metals' sheen, black. `cacheDisplay` (the snapshot hook) does
/// exactly that, and so may the fold veil's `CALayer.render(in:)`. The
/// translucent pair degrades there to a faint wash instead.
///
/// Seeded, so a material is the same on every launch and in every snapshot.
/// Every tile wraps seamlessly, and all of them are generated at 2x so the
/// texture is crisp on a Retina panel.
enum ShellMaterialTexture {

    /// The pair of tiles for one material, plus the number that turns a
    /// strength into the layers' opacity (see `opacity(forStrength:)`).
    struct Tiles {
        let light: NSImage
        let dark: NSImage
        /// The largest |f| in the generated field. The tiles store
        /// `|f| / fieldMax`, so the 8-bit grey never clips however far the
        /// field runs past ±1 (unit noise reaches about 3.5).
        let fieldMax: Double

        /// The design's unit: a field value of ±1 moves a pixel's lightness
        /// by `strength × 22 / 255`. The tile holds `|f| / fieldMax`, so the
        /// layer has to be drawn at `fieldMax` times that.
        func opacity(forStrength strength: Double) -> Double {
            min(strength * ShellMaterialTexture.unit * fieldMax, 1)
        }
    }

    /// Lightness per unit of field per unit of strength.
    static let unit: Double = 22.0 / 255.0

    /// Device pixels per point in every material tile.
    static let scale = 2

    static let plastic = tiles(from: field(for: .plastic))
    static let brushed = tiles(from: field(for: .brushed))
    static let blasted = tiles(from: field(for: .blasted))
    static let weave = tiles(from: field(for: .weave))

    /// The tiles for `material`, or nil for grain, which `carbonGrain` draws.
    /// Touching a static is what generates it, so a theme that never uses
    /// weave never pays for weave.
    static func tiles(for material: ShellMaterial) -> Tiles? {
        switch material {
        case .grain: return nil
        case .plastic: return plastic
        case .brushed: return brushed
        case .blasted: return blasted
        case .weave: return weave
        }
    }

    /// The soft diagonal band of light over the metals, as a fraction of the
    /// material's unit (`strength × 22/255`). One broad highlight is what
    /// makes brushed and blasted read as metal rather than as noise; the
    /// non-metals have none.
    static func sheenFactor(for material: ShellMaterial) -> Double {
        switch material {
        case .brushed: return 0.5
        case .blasted: return 0.4
        case .grain, .plastic, .weave: return 0
        }
    }

    // MARK: - Fields

    /// One material's signed field in device pixels, wrapping at its edges.
    struct Field {
        let width: Int
        let height: Int
        var values: [Float]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            values = [Float](repeating: 0, count: width * height)
        }

        /// Wraps both ways, so every filter below is seamless by construction.
        subscript(x: Int, y: Int) -> Float {
            get { values[wrap(y, height) * width + wrap(x, width)] }
            set { values[wrap(y, height) * width + wrap(x, width)] = newValue }
        }

        private func wrap(_ value: Int, _ size: Int) -> Int {
            let r = value % size
            return r < 0 ? r + size : r
        }
    }

    /// Generates `material`'s field. Internal so tests can check that each is
    /// deterministic and seamless without decoding an image.
    static func field(for material: ShellMaterial) -> Field {
        switch material {
        case .plastic: return plasticField()
        case .brushed: return brushedField()
        case .blasted: return blastedField()
        case .weave: return weaveField()
        case .grain: return Field(width: 1, height: 1)
        }
    }

    /// Orange peel: white noise softened by two wrapping 3 × 3 box blurs into
    /// low bumps, then lit from the top left by taking the slope along the
    /// diagonal. 256 pt.
    ///
    /// The noise is uniform in -0.5...0.5, not the unit-variance noise the
    /// metals use: the ×16 slope gain is what brings this field to about ±1,
    /// and with unit noise under it the same gain lands near ±4.5.
    private static func plasticField() -> Field {
        let side = 256 * scale
        var rng = SeededGenerator(seed: 0x504C_4153_5449_4331) // "PLASTIC1"
        var height = Field(width: side, height: side)
        for i in height.values.indices {
            height.values[i] = Float(rng.uniform() - 0.5)
        }
        height = boxBlur(boxBlur(height))
        var field = Field(width: side, height: side)
        let h = height.values
        for y in 0..<side {
            let above = ((y - 1 + side) % side) * side
            let below = ((y + 1) % side) * side
            for x in 0..<side {
                let left = (x - 1 + side) % side
                let right = (x + 1) % side
                field.values[y * side + x] = (h[above + left] - h[below + right]) * 16
            }
        }
        return field
    }

    /// Brushed: every row is its own slow walk along x (AR(1), coefficient
    /// 0.975, driven by unit noise), scaled 0.42, plus a per-row offset, so
    /// the strokes run long and horizontal and neighbouring rows differ.
    /// 512 × 128 pt: the 4:1 shape keeps a stroke from visibly repeating
    /// across a wide window.
    ///
    /// To wrap, each row's walk goes round twice over the same noise and only
    /// the second lap is kept: by then the walk has forgotten where it started
    /// (0.975 to the 1024th is about 1e-11), so its last pixel leads into its
    /// first exactly as any other pair of neighbours does.
    private static func brushedField() -> Field {
        let width = 512 * scale
        let height = 128 * scale
        var rng = SeededGenerator(seed: 0x4252_5553_4845_4431) // "BRUSHED1"
        var field = Field(width: width, height: height)
        var noise = [Float](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width { noise[x] = Float(rng.unitNoise()) }
            let offset = Float(0.22 * rng.unitNoise())
            var walk: Float = 0
            for lap in 0..<2 {
                for x in 0..<width {
                    walk = 0.975 * walk + noise[x]
                    if lap == 1 { field.values[y * width + x] = 0.42 * walk + offset }
                }
            }
        }
        return field
    }

    /// Bead-blasted: per device pixel, a little unit noise, with one pixel in
    /// 400 lifted where a bead left a facet that catches the light. Every
    /// pixel is independent, so the tile is seamless as it stands. 256 pt.
    private static func blastedField() -> Field {
        let side = 256 * scale
        var rng = SeededGenerator(seed: 0x424C_4153_5445_4431) // "BLASTED1"
        var field = Field(width: side, height: side)
        for i in field.values.indices {
            var value = 0.3 * rng.unitNoise()
            if rng.uniform() < 1.0 / 400.0 { value += 1.4 }
            field.values[i] = Float(value)
        }
        return field
    }

    /// Carbon weave: a 2 × 2 twill of 4 pt tows. Each tow is rounded across
    /// its width and dips at its ends where it goes under its neighbour, the
    /// horizontal ones catch more light than the vertical ones, and a little
    /// noise keeps the lacquer from looking printed. One twill repeat is 16
    /// pt; the tile is 64 pt so the noise doesn't repeat that often.
    private static func weaveField() -> Field {
        let side = 64 * scale
        let tow = 4 * scale
        var rng = SeededGenerator(seed: 0x5745_4156_4531_3131) // "WEAVE111"
        var field = Field(width: side, height: side)
        for y in 0..<side {
            for x in 0..<side {
                let i = x / tow
                let j = y / tow
                let horizontal = ((i + j) & 3) < 2
                let u = (Double(x % tow) + 0.5) / Double(tow)
                let v = (Double(y % tow) + 0.5) / Double(tow)
                let across = horizontal ? v : u
                let along = horizontal ? u : v
                let value = (sin(across * .pi) - 0.64) * 1.5
                    + (horizontal ? 0.55 : -0.25)
                    + (sin(along * .pi) - 0.64) * 0.35
                    + 0.18 * (rng.uniform() - 0.5)
                field.values[y * side + x] = Float(value)
            }
        }
        return field
    }

    /// A 3 × 3 box blur that wraps at the edges, so a blurred tile still tiles.
    /// Separable (a row pass, then a column pass), with the wrapped
    /// neighbours worked out once per row and column rather than per tap: it
    /// runs on the main thread the first time the material is drawn, and an
    /// unoptimised debug build is slow enough at nine wrapped taps a pixel to
    /// hold up the first frame by seconds.
    private static func boxBlur(_ source: Field) -> Field {
        let width = source.width
        let height = source.height
        let input = source.values
        var rows = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let left = (x - 1 + width) % width
                let right = (x + 1) % width
                rows[row + x] = input[row + left] + input[row + x] + input[row + right]
            }
        }
        var out = Field(width: width, height: height)
        for y in 0..<height {
            let above = ((y - 1 + height) % height) * width
            let row = y * width
            let below = ((y + 1) % height) * width
            for x in 0..<width {
                out.values[row + x] = (rows[above + x] + rows[row + x] + rows[below + x]) / 9
            }
        }
        return out
    }

    // MARK: - Encoding

    /// Splits a field into its light and dark tiles. A texel the other half
    /// owns is fully transparent in this one.
    static func tiles(from field: Field) -> Tiles {
        let fieldMax = max(Double(field.values.map(abs).max() ?? 0), .ulpOfOne)
        let count = field.width * field.height
        var light = [UInt8](repeating: 0, count: count * 4)
        var dark = [UInt8](repeating: 0, count: count * 4)
        for (index, value) in field.values.enumerated() {
            let alpha = UInt8(min(Double(abs(value)) / fieldMax * 255, 255).rounded())
            let i = index * 4
            if value > 0 {
                // White, premultiplied: (a, a, a, a).
                light[i] = alpha
                light[i + 1] = alpha
                light[i + 2] = alpha
                light[i + 3] = alpha
            } else {
                // Black: the colour is 0 premultiplied whatever the alpha.
                dark[i + 3] = alpha
            }
        }
        return Tiles(
            light: image(from: light, width: field.width, height: field.height),
            dark: image(from: dark, width: field.width, height: field.height),
            fieldMax: fieldMax
        )
    }

    /// Wraps a premultiplied RGBA buffer as an `NSImage` sized in points,
    /// `scale` pixels to the point. `CarbonTexture.image(from:)` only makes
    /// square tiles at one pixel size, and grain stays on it unchanged.
    private static func image(from bytes: [UInt8], width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width / scale, height: height / scale)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }
}

/// SplitMix64: tiny, fast and, unlike `SystemRandomNumberGenerator`, seedable,
/// which is the whole point. A material that came out different on every
/// launch could never be compared between two snapshots.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Roughly unit-variance noise: four uniforms summed and recentred, the
    /// mockup's own recipe (a cheap near-Gaussian).
    mutating func unitNoise() -> Double {
        (uniform() + uniform() + uniform() + uniform() - 2) * 1.73
    }
}

// MARK: - Drawing

extension View {

    /// The chassis's shell material (interface effects `grain`, `shellPlastic`,
    /// `shellBrushed`, `shellBlasted`, `shellWeave`). The one entry point:
    /// `ChassisLayer` passes the theme's resolved `shellMaterial`, so a theme
    /// carrying grain and a material draws only the material.
    ///
    /// Grain goes straight to `carbonGrain`, unchanged, so Carbon renders
    /// exactly as before. The others are masked around everything that called
    /// `grainFree()`, as grain is: the display glass, the rubber caps, art.
    /// A no-op for nil or a strength at or below 0: the bare view.
    @ViewBuilder
    func carbonShellMaterial(_ material: ShellMaterial?, strength: Double) -> some View {
        if let material, strength > 0 {
            if material == .grain {
                carbonGrain(strength)
            } else if let tiles = ShellMaterialTexture.tiles(for: material) {
                // The same shape as `carbonGrain`, which is known to blend
                // against the chassis correctly from here.
                compositingGroup()
                    .overlayPreferenceValue(GrainFreeKey.self) { holes in
                        GeometryReader { proxy in
                            ShellMaterialLayers(
                                material: material,
                                tiles: tiles,
                                strength: strength,
                                mask: GrainMask(holes: holes.map { (proxy[$0.bounds], $0.shape) })
                            )
                        }
                        .allowsHitTesting(false)
                    }
            } else {
                self
            }
        } else {
            self
        }
    }

    /// The same material on a surface that is not inside `ChassisLayer`: the
    /// mini player's glass, which is its own transparent window. Clipped to
    /// `shape`, since a `.plusLighter` texel over the window's transparent
    /// corners would draw a speck there, and grouped with the surface so the
    /// blend lands on it rather than on whatever is behind the window.
    ///
    /// Never grain: the mini player has never had grain, and giving it some
    /// would change Carbon. A no-op for nil, grain or 0: the bare view.
    @ViewBuilder
    func carbonShellMaterial<S: Shape>(_ material: ShellMaterial?, strength: Double, clippedTo shape: S) -> some View {
        if let material, strength > 0, let tiles = ShellMaterialTexture.tiles(for: material) {
            overlay(
                ShellMaterialLayers(material: material, tiles: tiles, strength: strength, mask: Color.black)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            )
            .compositingGroup()
        } else {
            self
        }
    }
}

/// The two tile layers and, for the metals, the sheen. `mask` is opaque where
/// the material may show.
private struct ShellMaterialLayers<Mask: View>: View {
    let material: ShellMaterial
    let tiles: ShellMaterialTexture.Tiles
    let strength: Double
    let mask: Mask

    var body: some View {
        let opacity = tiles.opacity(forStrength: strength)
        let sheen = ShellMaterialTexture.sheenFactor(for: material) * strength * ShellMaterialTexture.unit
        ZStack {
            Image(nsImage: tiles.light)
                .interpolation(.none)
                .resizable(resizingMode: .tile)
                .mask(mask)
                .blendMode(.plusLighter)
                .opacity(opacity)
            Image(nsImage: tiles.dark)
                .interpolation(.none)
                .resizable(resizingMode: .tile)
                .mask(mask)
                .blendMode(.plusDarker)
                .opacity(opacity)
            if sheen > 0 {
                // One static gradient, not tiled and not animated: the cost of
                // grain's flat veil, which ships. Peak just past the middle so
                // the band crosses the display end of the console. White at an
                // alpha, never an opaque grey, for the reason the tiles are.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.18),
                        .init(color: .white.opacity(sheen), location: 0.56),
                        .init(color: .clear, location: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .mask(mask)
                .blendMode(.plusLighter)
            }
        }
    }
}
