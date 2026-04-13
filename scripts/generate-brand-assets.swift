#!/usr/bin/env swift

import AppKit
import Foundation

private enum BrandPalette {
    static let paper = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.985, alpha: 1)
    static let mist = NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.97, alpha: 1)
    static let chrome = NSColor(calibratedRed: 0.79, green: 0.81, blue: 0.86, alpha: 1)
    static let slate = NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.23, alpha: 1)
    static let slateSoft = NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.39, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.17, green: 0.73, blue: 0.97, alpha: 1)
    static let cyanGlow = NSColor(calibratedRed: 0.44, green: 0.88, blue: 1, alpha: 1)
    static let amber = NSColor(calibratedRed: 1.0, green: 0.79, blue: 0.22, alpha: 1)
    static let coral = NSColor(calibratedRed: 0.92, green: 0.39, blue: 0.29, alpha: 1)
}

private struct Paths {
    let root: URL
    let brandingDir: URL
    let generatedDir: URL
    let iconPreviewPath: URL
    let splashPath: URL
    let aboutPreviewPath: URL
    let iconsetPath: URL
    let icnsPath: URL

    init(root: URL) {
        self.root = root
        self.brandingDir = root.appendingPathComponent("Branding", isDirectory: true)
        self.generatedDir = brandingDir.appendingPathComponent("Generated", isDirectory: true)
        self.iconPreviewPath = generatedDir.appendingPathComponent("CrateDiggerIcon-1024.png")
        self.splashPath = generatedDir.appendingPathComponent("CrateDiggerSplash.png")
        self.aboutPreviewPath = generatedDir.appendingPathComponent("CrateDiggerAboutPreview.png")
        self.iconsetPath = generatedDir.appendingPathComponent("CrateDigger.iconset", isDirectory: true)
        self.icnsPath = root
            .appendingPathComponent("Packaging", isDirectory: true)
            .appendingPathComponent("CrateDiggerApp", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("CrateDigger.icns")
    }
}

private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, colors: [NSColor], locations: [CGFloat], angle: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)
    gradient?.draw(in: path, angle: angle)
}

private func drawBackdrop(in rect: CGRect) {
    fillRoundedRect(
        rect,
        radius: rect.width * 0.22,
        colors: [BrandPalette.paper, BrandPalette.mist, BrandPalette.paper],
        locations: [0, 0.58, 1],
        angle: 90
    )

    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), xRadius: rect.width * 0.2, yRadius: rect.width * 0.2)
    BrandPalette.chrome.withAlphaComponent(0.55).setStroke()
    border.lineWidth = max(2, rect.width * 0.02)
    border.stroke()

    let glowLeft = NSBezierPath(ovalIn: CGRect(
        x: rect.minX + rect.width * 0.04,
        y: rect.minY + rect.height * 0.58,
        width: rect.width * 0.56,
        height: rect.height * 0.32
    ))
    BrandPalette.cyanGlow.withAlphaComponent(0.18).setFill()
    glowLeft.fill()

    let glowRight = NSBezierPath(ovalIn: CGRect(
        x: rect.minX + rect.width * 0.48,
        y: rect.minY + rect.height * 0.12,
        width: rect.width * 0.4,
        height: rect.height * 0.28
    ))
    BrandPalette.amber.withAlphaComponent(0.12).setFill()
    glowRight.fill()

    for index in 0..<10 {
        let grooveY = rect.minY + rect.height * (0.16 + CGFloat(index) * 0.067)
        let groove = NSBezierPath()
        groove.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: grooveY))
        groove.curve(
            to: CGPoint(x: rect.maxX - rect.width * 0.08, y: grooveY - rect.height * 0.03),
            controlPoint1: CGPoint(x: rect.midX - rect.width * 0.18, y: grooveY + rect.height * 0.03),
            controlPoint2: CGPoint(x: rect.midX + rect.width * 0.18, y: grooveY - rect.height * 0.08)
        )
        groove.lineWidth = max(1, rect.width * 0.0065)
        BrandPalette.chrome.withAlphaComponent(index.isMultiple(of: 2) ? 0.14 : 0.08).setStroke()
        groove.stroke()
    }
}

private func drawRecord(in rect: CGRect, rotationDegrees: CGFloat) {
    let save = NSGraphicsContext.current?.cgContext
    save?.saveGState()
    save?.translateBy(x: rect.midX, y: rect.midY)
    save?.rotate(by: rotationDegrees * .pi / 180)
    save?.translateBy(x: -rect.midX, y: -rect.midY)

    let discPath = NSBezierPath(ovalIn: rect)
    fillRoundedRect(rect, radius: rect.width / 2, colors: [
        BrandPalette.slate.blended(withFraction: 0.18, of: .black) ?? BrandPalette.slate,
        BrandPalette.slateSoft,
        BrandPalette.slate
    ], locations: [0, 0.58, 1], angle: 90)
    BrandPalette.paper.withAlphaComponent(0.12).setStroke()
    discPath.lineWidth = max(1.2, rect.width * 0.015)
    discPath.stroke()

    for ringScale in stride(from: 0.78, through: 0.34, by: -0.11) {
        let inset = rect.width * (1 - CGFloat(ringScale)) / 2
        let ringRect = rect.insetBy(dx: inset, dy: inset)
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = max(0.6, rect.width * 0.01)
        BrandPalette.paper.withAlphaComponent(0.07).setStroke()
        ring.stroke()
    }

    let labelRect = rect.insetBy(dx: rect.width * 0.34, dy: rect.height * 0.34)
    let labelPath = NSBezierPath(ovalIn: labelRect)
    BrandPalette.amber.setFill()
    labelPath.fill()

    let spindleRect = rect.insetBy(dx: rect.width * 0.47, dy: rect.height * 0.47)
    let spindlePath = NSBezierPath(ovalIn: spindleRect)
    BrandPalette.paper.setFill()
    spindlePath.fill()

    save?.restoreGState()
}

private func drawSleeve(in rect: CGRect, rotationDegrees: CGFloat, fill: NSColor, accent: NSColor) {
    let context = NSGraphicsContext.current?.cgContext
    context?.saveGState()
    context?.translateBy(x: rect.midX, y: rect.midY)
    context?.rotate(by: rotationDegrees * .pi / 180)
    context?.translateBy(x: -rect.midX, y: -rect.midY)

    let outer = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.1, yRadius: rect.width * 0.1)
    fill.setFill()
    outer.fill()
    accent.withAlphaComponent(0.45).setStroke()
    outer.lineWidth = max(1.4, rect.width * 0.03)
    outer.stroke()

    let stripeRect = CGRect(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.62, width: rect.width * 0.8, height: rect.height * 0.1)
    let stripe = NSBezierPath(roundedRect: stripeRect, xRadius: stripeRect.height / 2, yRadius: stripeRect.height / 2)
    accent.withAlphaComponent(0.25).setFill()
    stripe.fill()

    context?.restoreGState()
}

private func drawScanBeam(in rect: CGRect) {
    let context = NSGraphicsContext.current?.cgContext
    context?.saveGState()
    context?.translateBy(x: rect.midX, y: rect.midY)
    context?.rotate(by: -.pi / 9)
    context?.translateBy(x: -rect.midX, y: -rect.midY)

    let beamRect = CGRect(x: rect.minX + rect.width * 0.02, y: rect.midY - rect.height * 0.08, width: rect.width * 0.96, height: rect.height * 0.16)
    let beamPath = NSBezierPath(roundedRect: beamRect, xRadius: beamRect.height / 2, yRadius: beamRect.height / 2)
    fillRoundedRect(
        beamRect,
        radius: beamRect.height / 2,
        colors: [
            BrandPalette.cyan.withAlphaComponent(0.0),
            BrandPalette.cyanGlow.withAlphaComponent(0.78),
            BrandPalette.cyan.withAlphaComponent(0.0)
        ],
        locations: [0, 0.5, 1],
        angle: 0
    )
    beamPath.lineWidth = max(1, beamRect.height * 0.11)
    BrandPalette.cyanGlow.withAlphaComponent(0.68).setStroke()
    beamPath.stroke()

    for index in 0..<5 {
        let barWidth = beamRect.width * 0.08
        let gap = beamRect.width * 0.055
        let x = beamRect.minX + beamRect.width * 0.14 + CGFloat(index) * (barWidth + gap)
        let barRect = CGRect(x: x, y: beamRect.midY - beamRect.height * 0.3, width: barWidth, height: beamRect.height * 0.6)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barRect.width * 0.35, yRadius: barRect.width * 0.35)
        BrandPalette.paper.withAlphaComponent(index.isMultiple(of: 2) ? 0.85 : 0.55).setFill()
        bar.fill()
    }

    context?.restoreGState()
}

private func drawCrateMark(in rect: CGRect) {
    drawBackdrop(in: rect)

    let innerRect = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
    let sleeveBaseY = innerRect.minY + innerRect.height * 0.48
    let sleeveSize = CGSize(width: innerRect.width * 0.29, height: innerRect.height * 0.28)
    let sleeveRects = [
        CGRect(x: innerRect.minX + innerRect.width * 0.14, y: sleeveBaseY, width: sleeveSize.width, height: sleeveSize.height),
        CGRect(x: innerRect.minX + innerRect.width * 0.33, y: sleeveBaseY + innerRect.height * 0.06, width: sleeveSize.width, height: sleeveSize.height),
        CGRect(x: innerRect.minX + innerRect.width * 0.53, y: sleeveBaseY + innerRect.height * 0.02, width: sleeveSize.width, height: sleeveSize.height)
    ]

    drawSleeve(in: sleeveRects[0], rotationDegrees: -11, fill: BrandPalette.coral.withAlphaComponent(0.9), accent: BrandPalette.paper)
    drawSleeve(in: sleeveRects[1], rotationDegrees: 6, fill: BrandPalette.amber.withAlphaComponent(0.92), accent: BrandPalette.slate)
    drawSleeve(in: sleeveRects[2], rotationDegrees: 15, fill: BrandPalette.cyan.withAlphaComponent(0.88), accent: BrandPalette.paper)

    let crateRect = CGRect(
        x: innerRect.minX + innerRect.width * 0.12,
        y: innerRect.minY + innerRect.height * 0.18,
        width: innerRect.width * 0.76,
        height: innerRect.height * 0.42
    )
    let cratePath = NSBezierPath(roundedRect: crateRect, xRadius: crateRect.width * 0.08, yRadius: crateRect.width * 0.08)
    fillRoundedRect(
        crateRect,
        radius: crateRect.width * 0.08,
        colors: [BrandPalette.slate, BrandPalette.slateSoft, BrandPalette.slate],
        locations: [0, 0.55, 1],
        angle: 90
    )
    BrandPalette.paper.withAlphaComponent(0.18).setStroke()
    cratePath.lineWidth = max(2, crateRect.width * 0.03)
    cratePath.stroke()

    let braceInset = crateRect.width * 0.12
    for xFactor in [0.24, 0.5, 0.76] {
        let brace = NSBezierPath()
        let x = crateRect.minX + crateRect.width * CGFloat(xFactor)
        brace.move(to: CGPoint(x: x, y: crateRect.minY + crateRect.height * 0.14))
        brace.line(to: CGPoint(x: x, y: crateRect.maxY - crateRect.height * 0.14))
        brace.lineWidth = max(1.6, crateRect.width * 0.025)
        BrandPalette.paper.withAlphaComponent(0.12).setStroke()
        brace.stroke()
    }

    let lipRect = CGRect(
        x: crateRect.minX + braceInset * 0.45,
        y: crateRect.minY + crateRect.height * 0.18,
        width: crateRect.width - braceInset * 0.9,
        height: crateRect.height * 0.18
    )
    let lip = NSBezierPath(roundedRect: lipRect, xRadius: lipRect.height / 2, yRadius: lipRect.height / 2)
    BrandPalette.paper.withAlphaComponent(0.1).setFill()
    lip.fill()

    let recordRect = CGRect(
        x: innerRect.minX + innerRect.width * 0.44,
        y: innerRect.minY + innerRect.height * 0.2,
        width: innerRect.width * 0.42,
        height: innerRect.width * 0.42
    )
    drawRecord(in: recordRect, rotationDegrees: -14)
    drawScanBeam(in: recordRect.insetBy(dx: -recordRect.width * 0.08, dy: recordRect.height * 0.08))
}

private func drawPill(text: String, rect: CGRect, fill: NSColor, textColor: NSColor, fontSize: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    fill.setFill()
    path.fill()

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: textColor
    ]
    let size = text.size(withAttributes: attributes)
    let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 1)
    text.draw(at: point, withAttributes: attributes)
}

private func writePNG(to url: URL, size: NSSize, drawing: (CGRect) -> Void) throws {
    let image = NSImage(size: size)
    image.lockFocusFlipped(false)
    drawing(CGRect(origin: .zero, size: size))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CrateDigger.Branding", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG at \(url.path)"])
    }

    try data.write(to: url)
}

private func drawSplash(in rect: CGRect) {
    fillRoundedRect(
        rect,
        radius: 44,
        colors: [
            BrandPalette.paper,
            NSColor(calibratedRed: 0.83, green: 0.88, blue: 0.96, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.99, alpha: 1)
        ],
        locations: [0, 0.56, 1],
        angle: 90
    )

    for index in 0..<18 {
        let grooveY = rect.minY + rect.height * 0.08 + CGFloat(index) * rect.height * 0.045
        let groove = NSBezierPath()
        groove.move(to: CGPoint(x: rect.minX + rect.width * 0.05, y: grooveY))
        groove.curve(
            to: CGPoint(x: rect.maxX - rect.width * 0.04, y: grooveY - rect.height * 0.018),
            controlPoint1: CGPoint(x: rect.midX - rect.width * 0.2, y: grooveY + rect.height * 0.028),
            controlPoint2: CGPoint(x: rect.midX + rect.width * 0.18, y: grooveY - rect.height * 0.05)
        )
        groove.lineWidth = index.isMultiple(of: 2) ? 2.5 : 1.4
        BrandPalette.chrome.withAlphaComponent(index.isMultiple(of: 2) ? 0.12 : 0.06).setStroke()
        groove.stroke()
    }

    let markRect = CGRect(
        x: rect.minX + rect.width * 0.08,
        y: rect.minY + rect.height * 0.16,
        width: rect.height * 0.62,
        height: rect.height * 0.62
    )
    drawCrateMark(in: markRect)

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.095, weight: .black),
        .foregroundColor: BrandPalette.slate
    ]
    let titlePoint = CGPoint(x: rect.minX + rect.width * 0.46, y: rect.minY + rect.height * 0.58)
    "CrateDigger".draw(at: titlePoint, withAttributes: titleAttrs)

    let tagAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.038, weight: .semibold),
        .foregroundColor: BrandPalette.slateSoft
    ]
    let tagRect = CGRect(x: titlePoint.x, y: rect.minY + rect.height * 0.4, width: rect.width * 0.42, height: rect.height * 0.16)
    let tag = NSString(string: "A modern-retro workstation for scanning, previewing, and cleaning up unruly music libraries.")
    tag.draw(with: tagRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: tagAttrs)

    drawPill(
        text: "SCAN",
        rect: CGRect(x: titlePoint.x, y: rect.minY + rect.height * 0.27, width: rect.width * 0.1, height: rect.height * 0.07),
        fill: BrandPalette.cyan.withAlphaComponent(0.18),
        textColor: BrandPalette.slate,
        fontSize: rect.height * 0.026
    )
    drawPill(
        text: "PREVIEW",
        rect: CGRect(x: titlePoint.x + rect.width * 0.12, y: rect.minY + rect.height * 0.27, width: rect.width * 0.135, height: rect.height * 0.07),
        fill: BrandPalette.amber.withAlphaComponent(0.25),
        textColor: BrandPalette.slate,
        fontSize: rect.height * 0.026
    )
    drawPill(
        text: "CONVERT",
        rect: CGRect(x: titlePoint.x + rect.width * 0.275, y: rect.minY + rect.height * 0.27, width: rect.width * 0.135, height: rect.height * 0.07),
        fill: BrandPalette.coral.withAlphaComponent(0.18),
        textColor: BrandPalette.slate,
        fontSize: rect.height * 0.026
    )

    let footerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: rect.height * 0.022, weight: .semibold),
        .foregroundColor: BrandPalette.slateSoft.withAlphaComponent(0.86)
    ]
    "Swift + AppKit + FFmpeg Tooling".draw(
        at: CGPoint(x: titlePoint.x, y: rect.minY + rect.height * 0.17),
        withAttributes: footerAttrs
    )
}

private func drawAboutPreview(in rect: CGRect) {
    fillRoundedRect(
        rect,
        radius: 28,
        colors: [BrandPalette.paper, BrandPalette.mist, BrandPalette.paper],
        locations: [0, 0.58, 1],
        angle: 90
    )

    let cardRect = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.09)
    let card = NSBezierPath(roundedRect: cardRect, xRadius: 28, yRadius: 28)
    BrandPalette.paper.withAlphaComponent(0.84).setFill()
    card.fill()
    BrandPalette.chrome.withAlphaComponent(0.35).setStroke()
    card.lineWidth = 2
    card.stroke()

    let artRect = CGRect(
        x: cardRect.minX + cardRect.width * 0.045,
        y: cardRect.minY + cardRect.height * 0.16,
        width: cardRect.width * 0.34,
        height: cardRect.height * 0.68
    )
    drawCrateMark(in: artRect)

    let textX = cardRect.minX + cardRect.width * 0.45
    let eyebrowAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: rect.height * 0.024, weight: .bold),
        .foregroundColor: BrandPalette.cyan
    ]
    "MODERN RETRO AUDIO WORKBENCH".draw(at: CGPoint(x: textX, y: cardRect.minY + cardRect.height * 0.72), withAttributes: eyebrowAttrs)

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.07, weight: .black),
        .foregroundColor: BrandPalette.slate
    ]
    "CrateDigger".draw(at: CGPoint(x: textX, y: cardRect.minY + cardRect.height * 0.61), withAttributes: titleAttrs)

    let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.03, weight: .medium),
        .foregroundColor: BrandPalette.slateSoft
    ]
    let bodyRect = CGRect(x: textX, y: cardRect.minY + cardRect.height * 0.46, width: cardRect.width * 0.43, height: cardRect.height * 0.13)
    NSString(string: "Scan folders fast, inspect metadata and artwork, audition tracks, and convert chaotic libraries into cleaner destinations.").draw(
        with: bodyRect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: bodyAttrs
    )

    let featureY = cardRect.minY + cardRect.height * 0.34
    let features = [
        ("Scan", BrandPalette.cyan.withAlphaComponent(0.18)),
        ("Preview", BrandPalette.amber.withAlphaComponent(0.22)),
        ("Convert", BrandPalette.coral.withAlphaComponent(0.18))
    ]
    for (index, feature) in features.enumerated() {
        drawPill(
            text: feature.0.uppercased(),
            rect: CGRect(x: textX + CGFloat(index) * cardRect.width * 0.12, y: featureY, width: cardRect.width * 0.1, height: cardRect.height * 0.08),
            fill: feature.1,
            textColor: BrandPalette.slate,
            fontSize: rect.height * 0.022
        )
    }

    drawPill(
        text: "VERSION 0.1.0",
        rect: CGRect(x: textX, y: cardRect.minY + cardRect.height * 0.2, width: cardRect.width * 0.2, height: cardRect.height * 0.08),
        fill: BrandPalette.slate.withAlphaComponent(0.94),
        textColor: BrandPalette.paper,
        fontSize: rect.height * 0.02
    )

    let footerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.023, weight: .semibold),
        .foregroundColor: BrandPalette.slateSoft
    ]
    "Built with Swift, AppKit, and FFmpeg tooling.".draw(
        at: CGPoint(x: textX, y: cardRect.minY + cardRect.height * 0.12),
        withAttributes: footerAttrs
    )
}

private func generateIconset(paths: Paths) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: paths.iconsetPath.path) {
        try fileManager.removeItem(at: paths.iconsetPath)
    }
    try fileManager.createDirectory(at: paths.iconsetPath, withIntermediateDirectories: true)

    let sizes = [16, 32, 128, 256, 512]
    for size in sizes {
        let baseName = "icon_\(size)x\(size).png"
        let basePath = paths.iconsetPath.appendingPathComponent(baseName)
        try writePNG(to: basePath, size: NSSize(width: size, height: size)) { rect in
            drawCrateMark(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
        }

        let retinaName = "icon_\(size)x\(size)@2x.png"
        let retinaPath = paths.iconsetPath.appendingPathComponent(retinaName)
        let retinaSize = size * 2
        try writePNG(to: retinaPath, size: NSSize(width: retinaSize, height: retinaSize)) { rect in
            drawCrateMark(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
        }
    }

    try writePNG(to: paths.iconPreviewPath, size: NSSize(width: 1024, height: 1024)) { rect in
        drawCrateMark(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", paths.iconsetPath.path, "-o", paths.icnsPath.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "CrateDigger.Branding", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed with status \(process.terminationStatus)"])
    }

    try? fileManager.removeItem(at: paths.iconsetPath)
}

private func repositoryRoot() -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while current.path != "/" {
        if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
            return current
        }
        current.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func main() throws {
    let root = repositoryRoot()
    let paths = Paths(root: root)
    let fileManager = FileManager.default

    try fileManager.createDirectory(at: paths.generatedDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: paths.icnsPath.deletingLastPathComponent(), withIntermediateDirectories: true)

    try generateIconset(paths: paths)

    try writePNG(to: paths.splashPath, size: NSSize(width: 2048, height: 1280)) { rect in
        drawSplash(in: rect)
    }

    try writePNG(to: paths.aboutPreviewPath, size: NSSize(width: 1600, height: 1000)) { rect in
        drawAboutPreview(in: rect)
    }

    print("Generated icon preview: \(paths.iconPreviewPath.path)")
    print("Generated splash artwork: \(paths.splashPath.path)")
    print("Generated about preview: \(paths.aboutPreviewPath.path)")
    print("Generated app icon bundle: \(paths.icnsPath.path)")
}

do {
    try main()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
