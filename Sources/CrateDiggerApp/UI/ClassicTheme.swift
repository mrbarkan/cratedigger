import AppKit
import QuartzCore

enum ClassicTheme {
    static let accentYellow = NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.17, alpha: 1)
    static let accentHighlight = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.32, alpha: 1)
    static let accentShadow = NSColor(calibratedRed: 0.88, green: 0.64, blue: 0.08, alpha: 1)
    static let chromeStroke = NSColor(calibratedWhite: 0.72, alpha: 1)

    private static var cachedPinstripe: NSColor?

    static var pinstripeBackground: NSColor {
        if let cachedPinstripe {
            return cachedPinstripe
        }

        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
        for offset in stride(from: -12, through: 24, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: CGFloat(offset), y: 0))
            path.line(to: NSPoint(x: CGFloat(offset) + size.height, y: size.height))
            path.lineWidth = 1
            path.stroke()
        }

        image.unlockFocus()
        let color = NSColor(patternImage: image)
        cachedPinstripe = color
        return color
    }

    static func applyPinstripe(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = pinstripeBackground.cgColor
    }

    static func applyAquaAccent(to button: NSButton) {
        button.wantsLayer = true
        button.isBordered = false
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = NSColor(calibratedWhite: 0.15, alpha: 0.95)

        let gradient = CAGradientLayer()
        gradient.colors = [
            accentHighlight.cgColor,
            accentYellow.cgColor,
            accentShadow.withAlphaComponent(0.92).cgColor
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.cornerRadius = 7
        gradient.borderColor = chromeStroke.withAlphaComponent(0.85).cgColor
        gradient.borderWidth = 1
        gradient.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
        gradient.shadowOffset = CGSize(width: 0, height: -1)
        gradient.shadowRadius = 1.5
        gradient.name = "ClassicAquaGradient"
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        button.layer?.cornerRadius = 7
        button.layer?.masksToBounds = false

        button.layer?.sublayers?.removeAll(where: { $0.name == "ClassicAquaGradient" })
        gradient.frame = button.bounds
        button.layer?.insertSublayer(gradient, at: 0)
    }

    static func updateButtonGradient(_ button: NSButton) {
        guard let gradient = button.layer?.sublayers?.first(where: { $0.name == "ClassicAquaGradient" }) else {
            return
        }
        gradient.frame = button.bounds
    }
}
