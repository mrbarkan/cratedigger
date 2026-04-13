import AppKit

enum BrandArtworkPalette {
    static let paper = NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.988, alpha: 1)
    static let mist = NSColor(calibratedRed: 0.892, green: 0.922, blue: 0.97, alpha: 1)
    static let chrome = NSColor(calibratedRed: 0.784, green: 0.808, blue: 0.852, alpha: 1)
    static let slate = NSColor(calibratedRed: 0.145, green: 0.176, blue: 0.227, alpha: 1)
    static let slateSoft = NSColor(calibratedRed: 0.286, green: 0.325, blue: 0.392, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.17, green: 0.73, blue: 0.97, alpha: 1)
    static let cyanGlow = NSColor(calibratedRed: 0.44, green: 0.88, blue: 1.0, alpha: 1)
    static let amber = NSColor(calibratedRed: 1.0, green: 0.79, blue: 0.22, alpha: 1)
    static let coral = NSColor(calibratedRed: 0.92, green: 0.39, blue: 0.29, alpha: 1)
}

final class BrandBackdropView: NSView {
    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        let gradient = NSGradient(colorsAndLocations:
            (BrandArtworkPalette.paper, 0),
            (BrandArtworkPalette.mist, 0.56),
            (BrandArtworkPalette.paper, 1)
        )
        gradient?.draw(in: bounds, angle: 90)

        for index in 0..<18 {
            let grooveY = bounds.minY + bounds.height * 0.06 + CGFloat(index) * bounds.height * 0.05
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.minX + bounds.width * 0.05, y: grooveY))
            path.curve(
                to: NSPoint(x: bounds.maxX - bounds.width * 0.04, y: grooveY - bounds.height * 0.015),
                controlPoint1: NSPoint(x: bounds.midX - bounds.width * 0.21, y: grooveY + bounds.height * 0.028),
                controlPoint2: NSPoint(x: bounds.midX + bounds.width * 0.2, y: grooveY - bounds.height * 0.045)
            )
            path.lineWidth = index.isMultiple(of: 2) ? 2 : 1
            BrandArtworkPalette.chrome.withAlphaComponent(index.isMultiple(of: 2) ? 0.12 : 0.06).setStroke()
            path.stroke()
        }

        let cyanGlow = NSBezierPath(ovalIn: CGRect(
            x: bounds.minX + bounds.width * 0.02,
            y: bounds.minY + bounds.height * 0.48,
            width: bounds.width * 0.34,
            height: bounds.height * 0.26
        ))
        BrandArtworkPalette.cyanGlow.withAlphaComponent(0.1).setFill()
        cyanGlow.fill()

        let amberGlow = NSBezierPath(ovalIn: CGRect(
            x: bounds.maxX - bounds.width * 0.34,
            y: bounds.minY + bounds.height * 0.08,
            width: bounds.width * 0.28,
            height: bounds.height * 0.22
        ))
        BrandArtworkPalette.amber.withAlphaComponent(0.08).setFill()
        amberGlow.fill()
    }
}

final class GlassCardView: NSView {
    private let fillColor: NSColor
    private let borderColor: NSColor
    private let cornerRadius: CGFloat

    init(fillColor: NSColor, borderColor: NSColor, cornerRadius: CGFloat = 26) {
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor
        layer?.backgroundColor = fillColor.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class BrandPillView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(text: String, fill: NSColor, textColor: NSColor = BrandArtworkPalette.slate) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        label.stringValue = text
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = textColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class BrandFeatureRowView: NSView {
    init(title: String, description: String, tint: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dotView = NSView()
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = tint.cgColor
        dotView.layer?.cornerRadius = 5
        dotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = BrandArtworkPalette.slate

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        descriptionLabel.textColor = BrandArtworkPalette.slateSoft
        descriptionLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, descriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dotView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),

            textStack.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class BrandArtworkView: NSView {
    override var isOpaque: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 240, height: 240)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let frame = bounds.insetBy(dx: 8, dy: 8)
        drawBackdrop(in: frame)

        let innerRect = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
        let sleeveBaseY = innerRect.minY + innerRect.height * 0.5
        let sleeveSize = NSSize(width: innerRect.width * 0.29, height: innerRect.height * 0.28)

        drawSleeve(
            in: CGRect(x: innerRect.minX + innerRect.width * 0.14, y: sleeveBaseY, width: sleeveSize.width, height: sleeveSize.height),
            rotationDegrees: -11,
            fill: BrandArtworkPalette.coral.withAlphaComponent(0.92),
            accent: BrandArtworkPalette.paper
        )
        drawSleeve(
            in: CGRect(x: innerRect.minX + innerRect.width * 0.33, y: sleeveBaseY + innerRect.height * 0.05, width: sleeveSize.width, height: sleeveSize.height),
            rotationDegrees: 5,
            fill: BrandArtworkPalette.amber.withAlphaComponent(0.95),
            accent: BrandArtworkPalette.slate
        )
        drawSleeve(
            in: CGRect(x: innerRect.minX + innerRect.width * 0.53, y: sleeveBaseY + innerRect.height * 0.02, width: sleeveSize.width, height: sleeveSize.height),
            rotationDegrees: 15,
            fill: BrandArtworkPalette.cyan.withAlphaComponent(0.9),
            accent: BrandArtworkPalette.paper
        )

        let crateRect = CGRect(
            x: innerRect.minX + innerRect.width * 0.12,
            y: innerRect.minY + innerRect.height * 0.18,
            width: innerRect.width * 0.76,
            height: innerRect.height * 0.42
        )
        drawCrate(in: crateRect)

        let recordRect = CGRect(
            x: innerRect.minX + innerRect.width * 0.44,
            y: innerRect.minY + innerRect.height * 0.2,
            width: innerRect.width * 0.42,
            height: innerRect.width * 0.42
        )
        drawRecord(in: recordRect, rotationDegrees: -14)
        drawScanBeam(in: recordRect.insetBy(dx: -recordRect.width * 0.08, dy: recordRect.height * 0.08))
    }

    private func drawBackdrop(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        let gradient = NSGradient(colorsAndLocations:
            (BrandArtworkPalette.paper, 0),
            (BrandArtworkPalette.mist, 0.58),
            (BrandArtworkPalette.paper, 1)
        )
        gradient?.draw(in: path, angle: 90)

        BrandArtworkPalette.chrome.withAlphaComponent(0.55).setStroke()
        path.lineWidth = max(2, rect.width * 0.018)
        path.stroke()

        for index in 0..<10 {
            let grooveY = rect.minY + rect.height * (0.17 + CGFloat(index) * 0.065)
            let groove = NSBezierPath()
            groove.move(to: NSPoint(x: rect.minX + rect.width * 0.08, y: grooveY))
            groove.curve(
                to: NSPoint(x: rect.maxX - rect.width * 0.08, y: grooveY - rect.height * 0.03),
                controlPoint1: NSPoint(x: rect.midX - rect.width * 0.18, y: grooveY + rect.height * 0.03),
                controlPoint2: NSPoint(x: rect.midX + rect.width * 0.18, y: grooveY - rect.height * 0.08)
            )
            groove.lineWidth = max(1, rect.width * 0.006)
            BrandArtworkPalette.chrome.withAlphaComponent(index.isMultiple(of: 2) ? 0.14 : 0.08).setStroke()
            groove.stroke()
        }

        let glow = NSBezierPath(ovalIn: CGRect(
            x: rect.minX + rect.width * 0.04,
            y: rect.minY + rect.height * 0.58,
            width: rect.width * 0.54,
            height: rect.height * 0.28
        ))
        BrandArtworkPalette.cyanGlow.withAlphaComponent(0.18).setFill()
        glow.fill()
    }

    private func drawCrate(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.08, yRadius: rect.width * 0.08)
        let gradient = NSGradient(colorsAndLocations:
            (BrandArtworkPalette.slate, 0),
            (BrandArtworkPalette.slateSoft, 0.56),
            (BrandArtworkPalette.slate, 1)
        )
        gradient?.draw(in: path, angle: 90)

        BrandArtworkPalette.paper.withAlphaComponent(0.18).setStroke()
        path.lineWidth = max(2, rect.width * 0.03)
        path.stroke()

        for xFactor in [0.24, 0.5, 0.76] {
            let brace = NSBezierPath()
            let x = rect.minX + rect.width * CGFloat(xFactor)
            brace.move(to: NSPoint(x: x, y: rect.minY + rect.height * 0.14))
            brace.line(to: NSPoint(x: x, y: rect.maxY - rect.height * 0.14))
            brace.lineWidth = max(1.6, rect.width * 0.024)
            BrandArtworkPalette.paper.withAlphaComponent(0.12).setStroke()
            brace.stroke()
        }

        let lipRect = CGRect(
            x: rect.minX + rect.width * 0.1,
            y: rect.minY + rect.height * 0.18,
            width: rect.width * 0.8,
            height: rect.height * 0.18
        )
        let lip = NSBezierPath(roundedRect: lipRect, xRadius: lipRect.height / 2, yRadius: lipRect.height / 2)
        BrandArtworkPalette.paper.withAlphaComponent(0.08).setFill()
        lip.fill()
    }

    private func drawSleeve(in rect: CGRect, rotationDegrees: CGFloat, fill: NSColor, accent: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotationDegrees * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        let outer = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.1, yRadius: rect.width * 0.1)
        fill.setFill()
        outer.fill()
        accent.withAlphaComponent(0.45).setStroke()
        outer.lineWidth = max(1.3, rect.width * 0.03)
        outer.stroke()

        let stripeRect = CGRect(
            x: rect.minX + rect.width * 0.1,
            y: rect.minY + rect.height * 0.62,
            width: rect.width * 0.8,
            height: rect.height * 0.11
        )
        let stripe = NSBezierPath(roundedRect: stripeRect, xRadius: stripeRect.height / 2, yRadius: stripeRect.height / 2)
        accent.withAlphaComponent(0.25).setFill()
        stripe.fill()
        context.restoreGState()
    }

    private func drawRecord(in rect: CGRect, rotationDegrees: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotationDegrees * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        let path = NSBezierPath(ovalIn: rect)
        let gradient = NSGradient(colorsAndLocations:
            (BrandArtworkPalette.slate, 0),
            (BrandArtworkPalette.slateSoft, 0.56),
            (BrandArtworkPalette.slate, 1)
        )
        gradient?.draw(in: path, angle: 90)
        BrandArtworkPalette.paper.withAlphaComponent(0.12).setStroke()
        path.lineWidth = max(1, rect.width * 0.015)
        path.stroke()

        for ringScale in stride(from: CGFloat(0.78), through: 0.34, by: -0.11) {
            let inset = rect.width * (1 - ringScale) / 2
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = max(0.6, rect.width * 0.009)
            BrandArtworkPalette.paper.withAlphaComponent(0.07).setStroke()
            ring.stroke()
        }

        let labelRect = rect.insetBy(dx: rect.width * 0.34, dy: rect.width * 0.34)
        BrandArtworkPalette.amber.setFill()
        NSBezierPath(ovalIn: labelRect).fill()

        let spindleRect = rect.insetBy(dx: rect.width * 0.47, dy: rect.width * 0.47)
        BrandArtworkPalette.paper.setFill()
        NSBezierPath(ovalIn: spindleRect).fill()
        context.restoreGState()
    }

    private func drawScanBeam(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: -.pi / 9)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        let beamRect = CGRect(
            x: rect.minX + rect.width * 0.02,
            y: rect.midY - rect.height * 0.08,
            width: rect.width * 0.96,
            height: rect.height * 0.16
        )
        let beam = NSBezierPath(roundedRect: beamRect, xRadius: beamRect.height / 2, yRadius: beamRect.height / 2)
        let gradient = NSGradient(colorsAndLocations:
            (BrandArtworkPalette.cyan.withAlphaComponent(0), 0),
            (BrandArtworkPalette.cyanGlow.withAlphaComponent(0.78), 0.5),
            (BrandArtworkPalette.cyan.withAlphaComponent(0), 1)
        )
        gradient?.draw(in: beam, angle: 0)
        BrandArtworkPalette.cyanGlow.withAlphaComponent(0.6).setStroke()
        beam.lineWidth = max(1, beamRect.height * 0.12)
        beam.stroke()

        for index in 0..<5 {
            let barWidth = beamRect.width * 0.08
            let gap = beamRect.width * 0.055
            let x = beamRect.minX + beamRect.width * 0.14 + CGFloat(index) * (barWidth + gap)
            let barRect = CGRect(x: x, y: beamRect.midY - beamRect.height * 0.3, width: barWidth, height: beamRect.height * 0.6)
            let bar = NSBezierPath(roundedRect: barRect, xRadius: barRect.width * 0.35, yRadius: barRect.width * 0.35)
            BrandArtworkPalette.paper.withAlphaComponent(index.isMultiple(of: 2) ? 0.85 : 0.55).setFill()
            bar.fill()
        }

        context.restoreGState()
    }
}
