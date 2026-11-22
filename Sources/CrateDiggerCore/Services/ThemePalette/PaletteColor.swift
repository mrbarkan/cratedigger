import Foundation

/// A colour in OKLCH: perceptual lightness (0...1), chroma, hue in degrees (0..<360).
public struct OKLCH: Equatable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

/// An sRGB colour (components 0...1) with the colour maths the theme palette recipe needs:
/// hex I/O, OKLab/OKLCH conversion (Björn Ottosson's matrices), WCAG 2 contrast.
public struct PaletteColor: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    // MARK: Hex

    /// Accepts `RRGGBB` or `RRGGBBAA`, with or without a leading `#`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              s.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((value >> 16) & 0xFF) / 255,
                      g: Double((value >> 8) & 0xFF) / 255,
                      b: Double(value & 0xFF) / 255)
        } else {
            self.init(r: Double((value >> 24) & 0xFF) / 255,
                      g: Double((value >> 16) & 0xFF) / 255,
                      b: Double((value >> 8) & 0xFF) / 255,
                      a: Double(value & 0xFF) / 255)
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour is not fully opaque.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        var out = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        if a < 1 { out += String(format: "%02X", byte(a)) }
        return out
    }

    // MARK: OKLCH

    public var oklch: OKLCH {
        let lab = oklab
        let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        return OKLCH(l: lab.l, c: c, h: c < 1e-6 ? 0 : h)
    }

    /// Builds a colour from OKLCH. An out-of-gamut request keeps lightness and hue and
    /// gives up chroma until it fits sRGB.
    public init(oklch: OKLCH, alpha: Double = 1) {
        let l = min(max(oklch.l, 0), 1)
        let hue = oklch.h * .pi / 180
        let cosH = cos(hue), sinH = sin(hue)

        func linear(_ c: Double) -> (Double, Double, Double) {
            Self.linearRGB(l: l, a: c * cosH, b: c * sinH)
        }
        func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
            let eps = 1e-6
            return rgb.0 >= -eps && rgb.0 <= 1 + eps
                && rgb.1 >= -eps && rgb.1 <= 1 + eps
                && rgb.2 >= -eps && rgb.2 <= 1 + eps
        }

        var chroma = max(oklch.c, 0)
        if !inGamut(linear(chroma)) {
            var lo = 0.0, hi = chroma
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if inGamut(linear(mid)) { lo = mid } else { hi = mid }
            }
            chroma = lo
        }
        let rgb = linear(chroma)
        self.init(r: Self.encode(rgb.0), g: Self.encode(rgb.1), b: Self.encode(rgb.2),
                  a: min(max(alpha, 0), 1))
    }

    // MARK: Luminance and contrast

    /// WCAG 2 relative luminance of the colour's RGB (alpha ignored).
    public var relativeLuminance: Double {
        let lin = linearComponents
        return 0.2126 * lin.r + 0.7152 * lin.g + 0.0722 * lin.b
    }

    /// WCAG 2 contrast ratio, 1...21. `a` is composited over `b` first when translucent;
    /// `b` itself is treated as opaque.
    public static func contrast(_ a: PaletteColor, _ b: PaletteColor) -> Double {
        let opaqueB = PaletteColor(r: b.r, g: b.g, b: b.b)
        let top = a.a < 1 ? a.composited(over: opaqueB) : a
        let l1 = top.relativeLuminance, l2 = opaqueB.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Euclidean distance in OKLab.
    public func distance(to other: PaletteColor) -> Double {
        let p = oklab, q = other.oklab
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    // MARK: Internals

    /// Source-over onto an opaque background; the result is opaque.
    private func composited(over bg: PaletteColor) -> PaletteColor {
        PaletteColor(r: r * a + bg.r * (1 - a),
                     g: g * a + bg.g * (1 - a),
                     b: b * a + bg.b * (1 - a))
    }

    private var linearComponents: (r: Double, g: Double, b: Double) {
        (Self.decode(r), Self.decode(g), Self.decode(b))
    }

    private var oklab: (l: Double, a: Double, b: Double) {
        let lin = linearComponents
        let l = cbrt(0.4122214708 * lin.r + 0.5363325363 * lin.g + 0.0514459929 * lin.b)
        let m = cbrt(0.2119034982 * lin.r + 0.6806995451 * lin.g + 0.1073969566 * lin.b)
        let s = cbrt(0.0883024619 * lin.r + 0.2817188376 * lin.g + 0.6299787005 * lin.b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func linearRGB(l: Double, a: Double, b: Double) -> (Double, Double, Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        return (4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
                -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
                -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
    }

    /// sRGB transfer function, encoded to linear.
    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Linear to sRGB-encoded, clamped to 0...1.
    private static func encode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
