#if canImport(XCTest)
import AppKit
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The renderer maps each semantic `BusyInk` onto the glass theme (spec
/// §2.2). Monochrome is not a branch in the renderer: it falls out of the
/// map, because the glass hands `BusyCanvas` its `monochromeGlass` theme.
@MainActor
final class BusyInkPaletteTests: XCTestCase {
    func testInksMapOntoTheGlassTheme() {
        let theme = CarbonTheme.carbon
        let palette = BusyInkPalette(theme: theme)

        XCTAssertEqual(rgba(palette.color(.foreground)), rgba(theme.oledForeground))
        XCTAssertEqual(rgba(palette.color(.cool)), rgba(theme.cyan))
        XCTAssertEqual(rgba(palette.color(.hot)), rgba(theme.meterHot))
        XCTAssertEqual(rgba(palette.color(.background)), rgba(theme.oledSurface))

        var dim = rgba(theme.oledForeground)
        dim.a = (dim.a * 0.26 * 1000).rounded() / 1000
        XCTAssertEqual(rgba(palette.color(.dim)), dim)
    }

    /// The stored fields and `color(_:)` are the same map.
    func testColorReadsTheStoredFields() {
        let palette = BusyInkPalette(theme: .carbon)
        XCTAssertEqual(palette.color(.foreground), palette.foreground)
        XCTAssertEqual(palette.color(.cool), palette.cool)
        XCTAssertEqual(palette.color(.hot), palette.hot)
        XCTAssertEqual(palette.color(.dim), palette.dim)
        XCTAssertEqual(palette.color(.background), palette.background)
    }

    /// Off a monochrome glass a pinned Meter High is honoured: hot is red.
    func testPinnedMeterHotDrawsHotOnColourGlass() {
        let palette = BusyInkPalette(theme: MonochromeGlassTests.llamaLikeTheme())
        XCTAssertEqual(rgba(palette.color(.hot)), RGBA(r: 1, g: 0, b: 0, a: 1))
    }

    /// Under a monochrome definition with `meterHot` pinned (Llama '97),
    /// cool, hot and foreground are one phosphor, and nothing is red.
    func testMonochromeCollapsesCoolAndHotOntoForeground() {
        let glass = MonochromeGlassTests.llamaLikeTheme().monochromeGlass
        let palette = BusyInkPalette(theme: glass)

        let phosphor = rgba(glass.oledForeground)
        XCTAssertEqual(rgba(palette.color(.foreground)), phosphor)
        XCTAssertEqual(rgba(palette.color(.cool)), phosphor)
        XCTAssertEqual(rgba(palette.color(.hot)), phosphor)
        for ink in BusyInk.allCases where ink != .background {
            let c = rgba(palette.color(ink))
            XCTAssertFalse(c.r > 0.5 && c.g < 0.2, "\(ink) draws red on monochrome glass: \(c)")
        }
    }

    /// Spec §2.1's glow rule, as the renderer applies it: strokes glow,
    /// fills with no stroke glow, a fill under a stroke does not, a
    /// background fill never does, and text never does.
    func testGlowRule() {
        typealias G = BusyCanvas
        XCTAssertTrue(G.glows(stroke: .foreground))
        XCTAssertTrue(G.glows(fill: .cool, under: nil))
        XCTAssertFalse(G.glows(fill: .cool, under: .foreground))
        XCTAssertFalse(G.glows(fill: .background, under: nil))
        XCTAssertFalse(G.glows(stroke: .background))
    }

    /// Fit is letterboxed, centred and never stretched (spec §2.2): a
    /// 220 × 84 frame draws the 240 × 100 scene at 201.6 × 84.
    func testFitLetterboxesTheScene() {
        let fit = BusyCanvas.fit(BusyDrawing.sceneSize, into: CGSize(width: 220, height: 84))
        XCTAssertEqual(fit.scale, 0.84, accuracy: 1e-9)
        XCTAssertEqual(fit.rect.width, 201.6, accuracy: 1e-9)
        XCTAssertEqual(fit.rect.height, 84, accuracy: 1e-9)
        XCTAssertEqual(fit.rect.minX, (220 - 201.6) / 2, accuracy: 1e-9)
        XCTAssertEqual(fit.rect.minY, 0, accuracy: 1e-9)

        let p = CGPoint(x: 240, y: 100).applying(fit.transform)
        XCTAssertEqual(p.x, fit.rect.maxX, accuracy: 1e-9)
        XCTAssertEqual(p.y, fit.rect.maxY, accuracy: 1e-9)
    }

    /// An empty or degenerate frame fits nothing rather than dividing by zero.
    func testFitOfAnEmptyFrameIsEmpty() {
        let fit = BusyCanvas.fit(BusyDrawing.sceneSize, into: .zero)
        XCTAssertEqual(fit.scale, 0)
        XCTAssertTrue(fit.rect.isEmpty)
        let none = BusyCanvas.fit(.zero, into: CGSize(width: 10, height: 10))
        XCTAssertEqual(none.scale, 0)
    }

    /// Batching keeps order (background fills occlude) and only merges
    /// neighbours that share ink, style, glow and weight.
    func testBatchingMergesOnlyMatchingNeighbours() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.line(0, 0, 10, 0)
        d.line(0, 5, 10, 5)                         // same as above: one batch
        d.rect(2, 2, 4, 4, nil, fill: .background)  // occluder: new batch
        d.line(0, 9, 10, 9)                         // foreground again: new batch
        d.line(0, 9, 10, 9, weight: 2.2)            // heavier: new batch
        d.text("A", 1, 1)                           // text: its own
        d.text("B", 1, 1)                           // text never batches
        let runs = BusyCanvas.batches(d.shapes)
        XCTAssertEqual(runs.map(\.shapes.count), [2, 1, 1, 1, 1, 1])
    }

    /// A stroke-and-fill shape draws its fill (no glow) and then its stroke
    /// (glow), so it splits into two passes.
    func testStrokedFillSplitsIntoFillThenStroke() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.circle(50, 50, 10, .foreground, fill: .background)
        let runs = BusyCanvas.batches(d.shapes)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.key, BusyCanvas.BatchKey(ink: .background, mode: .fill, glows: false, weight: 1))
        XCTAssertEqual(runs.last?.key, BusyCanvas.BatchKey(ink: .foreground, mode: .stroke, glows: true, weight: 1))
    }
}
#endif
