import Foundation

/// Pixels in, pixels out: draws the LCD grid (and the handheld's washed
/// colour) over a cover. No AppKit.
public enum CoverScreenRenderer {
    private static let blackGap: (Float, Float, Float) = (0, 0, 0)
    private static let handheldGap: (Float, Float, Float) = (26, 25, 21)

    /// `source`: RGBA8 sRGB, opaque, `count * count` pixels for `pixel` and
    /// `handheld`; `lcdSide * lcdSide` for `grid`. Returns RGBA8 sRGB,
    /// `lcdSide * lcdSide`, opaque. A source of the wrong size, or a layout
    /// with no screen, returns an opaque black image of the layout's size
    /// (empty when `count == 0`).
    ///
    /// `isCancelled` is asked once per output row; when it answers true the
    /// render stops and returns an empty array, which no caller can mistake
    /// for a picture.
    public static func render(source: [UInt8], look: CoverScreenLook,
                              layout: CoverScreenLayout, gridStrength: Double,
                              isCancelled: () -> Bool = { false }) -> [UInt8] {
        let side = layout.lcdSide
        let count = layout.count
        let cell = layout.cell
        guard count > 0, side > 0, cell > 0 else { return [] }
        let total = side * side * 4
        var out = [UInt8](repeating: 0, count: total)
        let expected = (look == .grid) ? side * side * 4 : count * count * 4
        guard source.count == expected else {
            var i = 3
            while i < total { out[i] = 255; i += 4 }
            return out
        }

        let strength = Float(min(1, max(0, gridStrength.isFinite ? gridStrength : 0)))
        let gap = (look == .handheld) ? handheldGap : blackGap

        // Per-cell coverage (0...1), then the per-position weights and the gain.
        let coverage = cellCoverage(cell: cell)
        var meanLit: Float = 0
        for c in coverage { meanLit += 1 - strength * c }
        meanLit /= Float(coverage.count)
        let gain = meanLit > 0 ? min(1.35, 1 / meanLit) : 1.35
        var litWeight = [Float](repeating: 0, count: coverage.count)
        var gapWeight = [Float](repeating: 0, count: coverage.count)
        for i in 0..<coverage.count {
            let a = strength * coverage[i]
            litWeight[i] = gain * (1 - a)
            gapWeight[i] = a
        }
        let gapR = gap.0, gapG = gap.1, gapB = gap.2

        let finished: Bool = source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                litWeight.withUnsafeBufferPointer { lw in
                    gapWeight.withUnsafeBufferPointer { gw in
                        for y in 0..<side {
                            if isCancelled() { return false }
                            let cy = y % cell
                            let ly = y / cell
                            for x in 0..<side {
                                let ci = cy * cell + (x % cell)
                                let lit: (Float, Float, Float)
                                if look == .grid {
                                    let s = (y * side + x) * 4
                                    lit = (Float(src[s]), Float(src[s + 1]), Float(src[s + 2]))
                                } else {
                                    let s = (ly * count + x / cell) * 4
                                    if look == .handheld {
                                        let t = handheldTone(r: src[s], g: src[s + 1], b: src[s + 2])
                                        lit = (Float(t.0), Float(t.1), Float(t.2))
                                    } else {
                                        lit = (Float(src[s]), Float(src[s + 1]), Float(src[s + 2]))
                                    }
                                }
                                let l = lw[ci], g = gw[ci]
                                let d = (y * side + x) * 4
                                dst[d] = clamp(lit.0 * l + gapR * g)
                                dst[d + 1] = clamp(lit.1 * l + gapG * g)
                                dst[d + 2] = clamp(lit.2 * l + gapB * g)
                                dst[d + 3] = 255
                            }
                        }
                        return true
                    }
                }
            }
        }
        return finished ? out : []
    }

    /// The colour of the unlit panel (nothing playing, no art, a stream with
    /// no thumbnail), from the theme's display glass in sRGB. A pale glass is
    /// used as it is: an unlit reflective LCD is the colour of its glass. A
    /// dark one is taken 40% toward black, so the panel reads as switched off
    /// beside the lit display rather than as a dim picture.
    /// "Pale" is the same perceived-brightness test (> 0.5) as
    /// `Color.themeLuminance`, which picks `oledSurfaceShade`.
    public static func unlitColor(r: UInt8, g: UInt8, b: UInt8) -> (UInt8, UInt8, UInt8) {
        let luminance = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
        guard luminance <= 0.5 else { return (r, g, b) }
        func dim(_ v: UInt8) -> UInt8 { UInt8((Double(v) * 0.6).rounded()) }
        return (dim(r), dim(g), dim(b))
    }

    /// A flat `count * count` RGBA8 source of one opaque colour: what the
    /// unlit panel is run through `render` as, so its grid is the real grid.
    public static func flatSource(r: UInt8, g: UInt8, b: UInt8, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var source = [UInt8](repeating: 255, count: count * count * 4)
        var i = 0
        while i < source.count {
            source[i] = r; source[i + 1] = g; source[i + 2] = b
            i += 4
        }
        return source
    }

    /// A non-backlit colour handheld's washed colour for one LCD pixel.
    public static func handheldTone(r: UInt8, g: UInt8, b: UInt8) -> (UInt8, UInt8, UInt8) {
        let k = (Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)) * 3
        return (handheldTable[k], handheldTable[k + 1], handheldTable[k + 2])
    }

    // MARK: - Internals

    @inline(__always)
    private static func clamp(_ v: Float) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v + 0.5)
    }

    /// Gap coverage across one cell: the last column and last row are gap; for
    /// cell >= 6 the gap is round(cell/6) wide and the lit pixel on each side
    /// of it is a shoulder at 0.35.
    static func cellCoverage(cell: Int) -> [Float] {
        var line = [Float](repeating: 0, count: cell)
        if cell >= 6 {
            let width = Int((Double(cell) / 6).rounded())
            for i in (cell - width)..<cell { line[i] = 1 }
            line[cell - width - 1] = 0.35
            line[0] = max(line[0], 0.35)
        } else {
            line[cell - 1] = 1
        }
        var table = [Float](repeating: 0, count: cell * cell)
        for y in 0..<cell {
            for x in 0..<cell {
                table[y * cell + x] = max(line[x], line[y])
            }
        }
        return table
    }

    private static func computeTone(r: Int, g: Int, b: Int) -> (UInt8, UInt8, UInt8) {
        func lin(_ v: Int) -> Double { pow(Double((v >> 3) * 255 / 31) / 255, 2.2) }
        let lr = lin(r), lg = lin(g), lb = lin(b)
        var nr = 0.80 * lr + 0.135 * lg + 0.065 * lb
        var ng = 0.03 * lr + 0.72 * lg + 0.25 * lb
        var nb = 0.14 * lr + 0.12 * lg + 0.74 * lb
        nr = nr * 0.90 + 0.012
        ng = ng * 0.90 + 0.012
        nb = nb * 0.86 + 0.009
        func enc(_ v: Double) -> UInt8 {
            let s = pow(min(1, max(0, v)), 1 / 2.2) * 255
            return UInt8(min(255, max(0, s.rounded())))
        }
        return (enc(nr), enc(ng), enc(nb))
    }

    /// 32 x 32 x 32 entries (5 bits per channel), three bytes each.
    private static let handheldTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 32768 * 3)
        for ri in 0..<32 {
            for gi in 0..<32 {
                for bi in 0..<32 {
                    let t = computeTone(r: ri << 3, g: gi << 3, b: bi << 3)
                    let k = (ri << 10 | gi << 5 | bi) * 3
                    table[k] = t.0; table[k + 1] = t.1; table[k + 2] = t.2
                }
            }
        }
        return table
    }()
}
