import CoreGraphics
import SwiftUI

/// The app icon, drawn once.
///
/// The record *is* the icon: an orange plate, a black disc with two deep
/// grooves and fine ones between, a paper label with an orange spindle.
///
/// This file is the single source for the artwork. `scripts/render-app-icon.sh`
/// compiles it together with a tiny main to write the `.iconset`, the
/// `.appiconset` and the Tahoe masters, and `AppIconView` draws the same
/// vectors on screen — so the About window shows the real icon even in a
/// `swift build` run, where `NSApplication.applicationIconImage` is still the
/// generic placeholder.
///
/// Keep it free of app dependencies: the render script compiles this file on
/// its own, so anything it imports beyond AppKit/SwiftUI breaks the pipeline.
enum AppIconArtwork {
    /// Apple's macOS icon grid: the rounded square occupies 824 of a 1024
    /// canvas, which is what makes the icon sit at the same size as its
    /// neighbours in the Dock. Tahoe's masters skip the inset (and the
    /// corners) because Icon Composer applies its own mask.
    static let contentRatio: CGFloat = 824.0 / 1024.0

    /// The three stacked layers, back to front. Icon Composer wants them as
    /// separate transparent PNGs to build the Liquid Glass depth from.
    enum Layer: Int, CaseIterable {
        case plate = 1
        case disc = 2
        case label = 3
    }

    /// Draws into `ctx`, filling a `canvas`-sized square at the origin.
    ///
    /// - Parameters:
    ///   - inset: use Apple's 824-in-1024 content box rather than full bleed.
    ///   - rounded: bake the squircle. False for a Tahoe master, where the
    ///     system supplies the shape.
    ///   - layers: which layers to draw, for exporting Icon Composer's stack.
    static func draw(
        in ctx: CGContext,
        canvas: CGFloat,
        inset: Bool = false,
        rounded: Bool = true,
        layers: Set<Layer> = Set(Layer.allCases)
    ) {
        let side = inset ? canvas * contentRatio : canvas
        let offset = (canvas - side) / 2

        ctx.saveGState()
        // Everything below is authored in the 1024-unit design space with y
        // growing downward, the way the artwork was drawn — the flip happens
        // once, here.
        ctx.translateBy(x: offset, y: offset + side)
        ctx.scaleBy(x: side / 1024, y: -side / 1024)

        if rounded {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                               cornerWidth: 228, cornerHeight: 228, transform: nil))
            ctx.clip()
        }

        if layers.contains(.plate) { drawPlate(ctx, rounded: rounded) }
        if layers.contains(.disc) { drawDisc(ctx) }
        if layers.contains(.label) { drawLabel(ctx) }

        if rounded { ctx.restoreGState() }
        ctx.restoreGState()
    }

    // MARK: - Layers

    private static func drawPlate(_ ctx: CGContext, rounded: Bool) {
        let box = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        ctx.saveGState()
        ctx.addRect(box)
        ctx.clip()
        linear(ctx, from: CGPoint(x: 512, y: 0), to: CGPoint(x: 512, y: 1024),
               stops: [(0, hex(0xFF8A5C)), (0.55, hex(0xFF6D3F)), (1, hex(0xE5552B))])
        // A single soft highlight off the top-left, the same light the Carbon
        // chassis is lit by.
        radial(ctx, center: CGPoint(x: 307, y: 102), radius: 922,
               stops: [(0, white(1, 0.18)), (1, white(1, 0))])
        ctx.restoreGState()

        // The inner hairline reads as the edge of a moulded part. On a
        // full-bleed master there is no edge to catch, so it is skipped.
        guard rounded else { return }
        ctx.setStrokeColor(white(1, 0.14))
        ctx.setLineWidth(4)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2, width: 1020, height: 1020),
                           cornerWidth: 226, cornerHeight: 226, transform: nil))
        ctx.strokePath()
    }

    private static func drawDisc(_ ctx: CGContext) {
        let center = CGPoint(x: 512, y: 512)
        let radius: CGFloat = 380
        let bounds = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.addEllipse(in: bounds)
        ctx.clip()
        radial(ctx, center: center, radius: radius,
               stops: [(0, hex(0x1B2026)), (0.6, hex(0x0C0F13)), (1, hex(0x05070A))])

        // Grooves: fine ones all the way out, two deep ones where a real
        // pressing has its band gaps.
        ctx.setStrokeColor(hex(0xF5F1E6, alpha: 0.035))
        ctx.setLineWidth(3)
        var r: CGFloat = 176
        while r <= 366 {
            ctx.addEllipse(in: ring(center, r))
            r += 12
        }
        ctx.strokePath()

        ctx.setStrokeColor(hex(0xF5F1E6, alpha: 0.12))
        ctx.setLineWidth(10)
        for deep in [CGFloat(300), CGFloat(220)] { ctx.addEllipse(in: ring(center, deep)) }
        ctx.strokePath()

        // The sheen a record catches across the diagonal.
        linear(ctx, from: CGPoint(x: bounds.minX, y: bounds.minY),
               to: CGPoint(x: bounds.maxX, y: bounds.maxY),
               stops: [(0, white(1, 0.12)), (0.45, white(1, 0)),
                       (0.75, white(1, 0)), (1, white(1, 0.05))])
        ctx.restoreGState()

        ctx.setStrokeColor(white(1, 0.14))
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: ring(center, 378))
    }

    private static func drawLabel(_ ctx: CGContext) {
        let center = CGPoint(x: 512, y: 512)
        let bounds = ring(center, 150)

        ctx.saveGState()
        ctx.addEllipse(in: bounds)
        ctx.clip()
        linear(ctx, from: CGPoint(x: 512, y: bounds.minY), to: CGPoint(x: 512, y: bounds.maxY),
               stops: [(0, hex(0xFFFDF7)), (1, hex(0xEDE6D6))])
        ctx.restoreGState()

        ctx.setStrokeColor(hex(0x000000, alpha: 0.10))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: ring(center, 148))

        ctx.setFillColor(hex(0xFF6D3F))
        ctx.fillEllipse(in: ring(center, 22))
    }

    // MARK: - Drawing helpers

    private static func ring(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.1) as CFArray,
            locations: stops.map(\.0)
        )!
    }

    private static func linear(_ ctx: CGContext, from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)]) {
        ctx.drawLinearGradient(gradient(stops), start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, stops: [(CGFloat, CGColor)]) {
        ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255,
                alpha
            ]
        )!
    }

    private static func white(_ level: CGFloat, _ alpha: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [level, level, level, alpha])!
    }
}

/// The app icon on screen, as vectors rather than the bundle's `.icns`.
///
/// A `swift build` run has no icon resource at all, so the About window would
/// otherwise show the generic application placeholder during development.
struct AppIconView: View {
    /// Full bleed by default: the squircle fills the view, which is how the
    /// icon reads in the Dock.
    var inset: Bool = false

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                AppIconArtwork.draw(in: cg, canvas: min(size.width, size.height), inset: inset)
            }
        }
        .accessibilityHidden(true)
    }
}
