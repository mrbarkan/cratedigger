import AppKit
import QuartzCore

enum ClassicTheme {
    static let accentYellow = NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.17, alpha: 1)
    static let accentHighlight = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.32, alpha: 1)
    static let accentShadow = NSColor(calibratedRed: 0.88, green: 0.64, blue: 0.08, alpha: 1)
    static let chromeStroke = NSColor(calibratedWhite: 0.72, alpha: 1)
    static let metalEdge = NSColor(calibratedWhite: 0.55, alpha: 1)
    static let metalHighlight = NSColor(calibratedWhite: 0.9, alpha: 1)
    static let metalLow = NSColor(calibratedWhite: 0.7, alpha: 1)
    static let lcdTop = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.86, alpha: 1)
    static let lcdMid = NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.78, alpha: 1)
    static let lcdBottom = NSColor(calibratedRed: 0.94, green: 0.9, blue: 0.7, alpha: 1)
    static let playlistBackgroundOdd = NSColor(calibratedWhite: 0.99, alpha: 1)
    static let playlistBackgroundEven = NSColor(calibratedWhite: 0.975, alpha: 1)
    static let playlistGridColor = NSColor(calibratedWhite: 0.82, alpha: 1)
    static let playlistPrimaryText = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let playlistSecondaryText = NSColor(calibratedWhite: 0.35, alpha: 1)

    private static var cachedPinstripe: NSColor?
    private static var cachedMetal: NSColor?

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
        for y in stride(from: 0, through: Int(size.height), by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: CGFloat(y)))
            path.line(to: NSPoint(x: size.width, y: CGFloat(y)))
            path.lineWidth = 1
            path.stroke()
        }

        image.unlockFocus()
        let color = NSColor(patternImage: image)
        cachedPinstripe = color
        return color
    }

    static var metalBackgroundColor: NSColor {
        if let cachedMetal {
            return cachedMetal
        }

        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()

        // Base vertical gradient
        let gradient = NSGradient(colorsAndLocations:
            (metalHighlight, 0.0),
            (metalLow, 0.45),
            (metalEdge, 1.0)
        )
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // Subtle noise
        let noise = NSImage(size: size)
        noise.lockFocus()
        for _ in 0..<600 {
            let x = CGFloat(Int.random(in: 0..<Int(size.width)))
            let y = CGFloat(Int.random(in: 0..<Int(size.height)))
            NSColor(calibratedWhite: 0.5, alpha: 0.04).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
        noise.unlockFocus()
        noise.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .plusLighter, fraction: 1)

        image.unlockFocus()
        let color = NSColor(patternImage: image)
        cachedMetal = color
        return color
    }

    static func applyMetal(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = metalBackgroundColor.cgColor
        view.layer?.masksToBounds = true
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
        button.contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 0.95)
        button.layer?.masksToBounds = false
        button.layer?.cornerRadius = 7

        removeExistingAquaLayers(from: button)
        let bounds = button.bounds

        let base = CAGradientLayer()
        base.name = "ClassicAquaBase"
        base.colors = [
            accentHighlight.cgColor,
            accentYellow.cgColor,
            accentShadow.withAlphaComponent(0.98).cgColor
        ]
        base.locations = [0, 0.45, 1]
        base.cornerRadius = 7
        base.borderColor = chromeStroke.blended(withFraction: 0.25, of: .black)?.cgColor ?? chromeStroke.cgColor
        base.borderWidth = 1
        base.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        base.shadowOffset = CGSize(width: 0, height: -1.2)
        base.shadowRadius = 1.6
        base.frame = bounds
        base.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let gloss = CAGradientLayer()
        gloss.name = "ClassicAquaGloss"
        gloss.colors = [
            NSColor.white.withAlphaComponent(0.7).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        gloss.locations = [0, 1]
        gloss.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * 0.45)
        gloss.cornerRadius = 7
        gloss.autoresizingMask = [.layerWidthSizable]

        let innerStroke = CALayer()
        innerStroke.name = "ClassicAquaInnerStroke"
        innerStroke.borderWidth = 1
        innerStroke.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        innerStroke.cornerRadius = 6.5
        innerStroke.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        innerStroke.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let outerStroke = CALayer()
        outerStroke.name = "ClassicAquaBorder"
        outerStroke.borderWidth = 1
        outerStroke.borderColor = chromeStroke.blended(withFraction: 0.35, of: .black)?.cgColor ?? chromeStroke.cgColor
        outerStroke.cornerRadius = 7
        outerStroke.frame = bounds
        outerStroke.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        button.layer?.insertSublayer(base, at: 0)
        button.layer?.insertSublayer(gloss, above: base)
        button.layer?.insertSublayer(innerStroke, above: gloss)
        button.layer?.insertSublayer(outerStroke, above: innerStroke)
    }

    static func applyPrimaryToolbarButtonStyle(to button: NSButton, title: String, minWidth: CGFloat) {
        button.title = title
        applyAquaAccent(to: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
    }

    static func updateButtonLayers(_ button: NSButton) {
        guard let layers = button.layer?.sublayers else { return }
        let bounds = button.bounds
        for layer in layers {
            switch layer.name {
            case "ClassicAquaBase":
                layer.frame = bounds
            case "ClassicAquaGloss":
                layer.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * 0.45)
            case "ClassicAquaInnerStroke":
                layer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
            case "ClassicAquaBorder":
                layer.frame = bounds
            default:
                continue
            }
        }
    }

    private static func removeExistingAquaLayers(from button: NSButton) {
        let names = Set(["ClassicAquaBase", "ClassicAquaGloss", "ClassicAquaInnerStroke", "ClassicAquaBorder", "ClassicAquaGradient"])
        button.layer?.sublayers?.removeAll(where: { layer in
            if let name = layer.name, names.contains(name) {
                layer.removeFromSuperlayer()
                return true
            }
            return false
        })
    }
}
