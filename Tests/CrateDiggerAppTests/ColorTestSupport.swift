#if canImport(XCTest)
import AppKit
import SwiftUI

/// sRGB components rounded to 1/1000, so two colours built different ways
/// (a hex string, a `Color(red:…)`, an `.opacity` modifier) compare by what
/// they draw rather than by how they were constructed.
///
/// Shared by `MonochromeGlassTests`, `BusyInkPaletteTests` and
/// `BusySignalSnapshotTests`.
struct RGBA: Equatable, CustomStringConvertible {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var description: String { String(format: "rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a) }
}

func rgba(_ color: Color) -> RGBA {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
    return RGBA(r: round3(ns.redComponent), g: round3(ns.greenComponent),
                b: round3(ns.blueComponent), a: round3(ns.alphaComponent))
}
#endif
