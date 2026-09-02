#!/usr/bin/env swift
//
// Draws the built-in themes' header logos as vector PDFs, one per appearance:
//
//   swift scripts/render-theme-logos.swift        (from the repo root)
//
// Each mark is drawn from the theme's own `theme.json` tokens, so the colours
// are the palette's, not a copy of it, and re-running after a palette change
// keeps the logo in step. The canvas is the header slot's shape (110 × 20pt)
// at 5×; the app aspect-fits it, so only the proportion matters.
//
// Writes `logo-light.pdf` and `logo-dark.pdf` into every `.cdtheme` that has a
// renderer below, and prints what it wrote.

import AppKit
import CoreText
import Foundation

let canvas = CGSize(width: 550, height: 100)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let themesDirectory = root.appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes")
let displayFontURL = root.appendingPathComponent("Sources/CrateDiggerApp/Resources/Fonts/MajorMonoDisplay-Regular.ttf")

// MARK: - Palette

struct Palette {
    let shared: [String: String]
    let layer: [String: String]

    subscript(_ key: String) -> CGColor {
        guard let hex = layer[key] ?? shared[key], let color = cgColor(hex) else {
            fatalError("token \(key) missing")
        }
        return color
    }

    func color(_ key: String, alpha: CGFloat) -> CGColor {
        self[key].copy(alpha: alpha)!
    }
}

func cgColor(_ hex: String) -> CGColor? {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard let value = UInt64(digits, radix: 16) else { return nil }
    let hasAlpha = digits.count == 8
    let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])
}

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [white, white, white, alpha])!
}

func palette(for theme: [String: Any], layer: String) -> Palette {
    let shared = theme["colors"] as? [String: String] ?? [:]
    let variant = (theme[layer] as? [String: Any])?["colors"] as? [String: String] ?? [:]
    return Palette(shared: shared, layer: variant)
}

// MARK: - Type

func registerDisplayFont() {
    CTFontManagerRegisterFontsForURL(displayFontURL as CFURL, .process, nil)
}

func displayFont(_ size: CGFloat) -> CTFont {
    CTFontCreateWithName("MajorMonoDisplay-Regular" as CFString, size, nil)
}

func systemFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

struct Line {
    let line: CTLine
    let width: CGFloat
    let capHeight: CGFloat

    init(_ text: String, font: CTFont, color: CGColor, tracking: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        // The kern after the last glyph is not ink.
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - tracking
        capHeight = CTFontGetCapHeight(font)
    }

    /// Draws with the caps centred on `centerY`.
    func draw(in context: CGContext, x: CGFloat, centerY: CGFloat) {
        context.textPosition = CGPoint(x: x, y: centerY - capHeight / 2)
        CTLineDraw(line, context)
    }

    /// Draws the text as a mask over a vertical gradient (`top` at the cap
    /// line, `bottom` at the baseline).
    func drawGradient(in context: CGContext, x: CGFloat, centerY: CGFloat, top: CGColor, bottom: CGColor) {
        context.saveGState()
        context.setTextDrawingMode(.clip)
        draw(in: context, x: x, centerY: centerY)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: x, y: centerY + capHeight / 2),
            end: CGPoint(x: x, y: centerY - capHeight / 2),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}

// MARK: - Shapes

func hexagon(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// A lamp: the dot with two soft rings, which is the glow a PDF can carry
/// without rasterising.
func lamp(in context: CGContext, at center: CGPoint, radius: CGFloat, color: CGColor) {
    for (extra, alpha) in [(radius * 1.6, 0.10), (radius * 0.8, 0.28), (0, 1.0)] as [(CGFloat, CGFloat)] {
        context.setFillColor(color.copy(alpha: alpha)!)
        context.fillEllipse(in: CGRect(x: center.x - radius - extra, y: center.y - radius - extra,
                                       width: (radius + extra) * 2, height: (radius + extra) * 2))
    }
}

func fillGradient(in context: CGContext, path: CGPath, from top: CGColor, to bottom: CGColor, rect: CGRect) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    context.restoreGState()
}

func strokeGradient(in context: CGContext, path: CGPath, width: CGFloat, from top: CGColor, to bottom: CGColor, rect: CGRect) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    context.restoreGState()
}

// MARK: - Carbon

/// A carbon ring, the hexagon every carbon lattice is built from, in the
/// console's own metal, with the brand's one orange lamp at a vertex. Then
/// the name, tracked wide in the interface sans. (The OLED's display face
/// was tried: its half-outlined glyphs read as a mistake at 20pt.)
func renderCarbon(_ context: CGContext, _ p: Palette) {
    let centerY = canvas.height / 2
    let name = Line("CARBON", font: systemFont(56, .regular), color: p["ink"], tracking: 12)
    let nameX = canvas.width - 10 - name.width
    name.draw(in: context, x: nameX, centerY: centerY)

    let radius: CGFloat = 30
    let center = CGPoint(x: nameX - 24 - radius, y: centerY)
    let outer = hexagon(center: center, radius: radius)
    strokeGradient(in: context, path: outer, width: 5, from: p["metalHi"], to: p["metalLo"],
                   rect: outer.boundingBox.insetBy(dx: -3, dy: -3))
    context.setFillColor(p.color("ink", alpha: 0.10))
    context.addPath(hexagon(center: center, radius: radius * 0.58))
    context.fillPath()
    lamp(in: context, at: CGPoint(x: center.x + radius * cos(.pi / 3), y: center.y + radius * sin(.pi / 3)),
         radius: 5, color: p["orange"])
}

// MARK: - Cobalt

/// Element 27 as its periodic-table tile, in the blue the theme is named
/// for, then the name in the interface sans.
func renderCobalt(_ context: CGContext, _ p: Palette) {
    let centerY = canvas.height / 2
    let name = Line("COBALT", font: systemFont(58, .semibold), color: p["ink"], tracking: 7)
    let nameX = canvas.width - 10 - name.width
    name.draw(in: context, x: nameX, centerY: centerY)

    let side: CGFloat = 78
    let tile = CGRect(x: nameX - 22 - side, y: centerY - side / 2, width: side, height: side)
    let shape = CGPath(roundedRect: tile, cornerWidth: 16, cornerHeight: 16, transform: nil)
    fillGradient(in: context, path: shape, from: p["orangeHi"], to: p["orangeLo"], rect: tile)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.setStrokeColor(gray(1, 0.35))
    context.setLineWidth(2)
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 15, cornerHeight: 15, transform: nil))
    context.strokePath()
    context.restoreGState()

    let symbol = Line("Co", font: systemFont(40, .bold), color: gray(1))
    symbol.draw(in: context, x: tile.midX - symbol.width / 2 + 1, centerY: tile.midY - 4)
    let number = Line("27", font: systemFont(13, .semibold), color: gray(1, 0.85))
    number.draw(in: context, x: tile.minX + 9, centerY: tile.maxY - 13)
}

// MARK: - Llama '97

/// Pixel art, because 1997 was. The llama in the console's wool with the
/// accent for a blanket, the name in a 5×7 bitmap face with the one-pixel
/// drop shadow every '97 title bar had.
let llamaSprite = [
    "...........1.1..",
    "...........111..",
    "..........11311.",
    "..........111111",
    "...........111..",
    "...........11...",
    "...........11...",
    "...........11...",
    ".1111111111111..",
    "11122222111111..",
    "11122222111111..",
    ".1111111111111..",
    ".111111111111...",
    ".11.......11....",
    ".11.......11....",
    ".11.......11....",
]

let bitmapFont: [Character: [String]] = [
    "L": ["1....", "1....", "1....", "1....", "1....", "1....", "11111"],
    "A": [".111.", "1...1", "1...1", "11111", "1...1", "1...1", "1...1"],
    "M": ["1...1", "11.11", "1.1.1", "1.1.1", "1...1", "1...1", "1...1"],
    "'": [".1", ".1", "1.", "..", "..", "..", ".."],
    "9": [".111.", "1...1", "1...1", ".1111", "....1", "....1", ".111."],
    "7": ["11111", "....1", "...1.", "..1..", ".1...", ".1...", ".1..."],
]

func drawPixels(_ rows: [String], in context: CGContext, origin: CGPoint, pixel: CGFloat, colors: [Character: CGColor]) {
    for (rowIndex, row) in rows.enumerated() {
        for (columnIndex, cell) in row.enumerated() {
            guard let color = colors[cell] else { continue }
            context.setFillColor(color)
            context.fill(CGRect(
                x: origin.x + CGFloat(columnIndex) * pixel,
                y: origin.y + CGFloat(rows.count - 1 - rowIndex) * pixel,
                width: pixel, height: pixel
            ))
        }
    }
}

func bitmapWidth(_ text: String, pixel: CGFloat) -> CGFloat {
    let columns = text.reduce(0) { $0 + (bitmapFont[$1]?.first?.count ?? 0) + 1 } - 1
    return CGFloat(columns) * pixel
}

func drawBitmapText(_ text: String, in context: CGContext, origin: CGPoint, pixel: CGFloat, color: CGColor) {
    var x = origin.x
    for character in text {
        guard let glyph = bitmapFont[character] else { continue }
        drawPixels(glyph, in: context, origin: CGPoint(x: x, y: origin.y), pixel: pixel, colors: ["1": color])
        x += CGFloat(glyph[0].count + 1) * pixel
    }
}

func renderLlama(_ context: CGContext, _ p: Palette, dark: Bool) {
    let pixel: CGFloat = 7
    let text = "LLAMA'97"
    let textWidth = bitmapWidth(text, pixel: pixel)
    let textX = canvas.width - 10 - textWidth
    let textY = (canvas.height - 7 * pixel) / 2
    // Shadow first, one pixel down and right; then the face.
    drawBitmapText(text, in: context, origin: CGPoint(x: textX + pixel, y: textY - pixel), pixel: pixel, color: p["orangeLo"])
    drawBitmapText(text, in: context, origin: CGPoint(x: textX, y: textY), pixel: pixel, color: p["ink"])

    let spritePixel: CGFloat = 5.5
    let spriteWidth = CGFloat(llamaSprite[0].count) * spritePixel
    let spriteHeight = CGFloat(llamaSprite.count) * spritePixel
    let spriteOrigin = CGPoint(x: textX - 22 - spriteWidth, y: (canvas.height - spriteHeight) / 2)
    drawPixels(llamaSprite, in: context, origin: spriteOrigin, pixel: spritePixel, colors: [
        "1": dark ? p["metalHi"] : p["metalDeep"],
        "2": p["orange"],
        "3": dark ? p["chassisDeep"] : p["chassisHi"],
    ])
}

// MARK: - Main

registerDisplayFont()

let renderers: [String: (CGContext, Palette, Bool) -> Void] = [
    "carbon": { context, palette, _ in renderCarbon(context, palette) },
    "cobalt": { context, palette, _ in renderCobalt(context, palette) },
    "llama-97": { context, palette, dark in renderLlama(context, palette, dark: dark) },
]

let bundles = try FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "cdtheme" }

for bundle in bundles {
    let manifestURL = bundle.appendingPathComponent("theme.json")
    let theme = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
    guard let id = theme["id"] as? String, let render = renderers[id] else {
        print("skip \(bundle.lastPathComponent): no renderer")
        continue
    }
    for layer in ["light", "dark"] {
        let output = bundle.appendingPathComponent("logo-\(layer).pdf")
        var mediaBox = CGRect(origin: .zero, size: canvas)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("could not open \(output.path)")
        }
        context.beginPDFPage(nil)
        context.setAllowsAntialiasing(true)
        render(context, palette(for: theme, layer: layer), layer == "dark")
        context.endPDFPage()
        context.closePDF()
        print("wrote \(output.path.replacingOccurrences(of: root.path + "/", with: ""))")
    }
}
