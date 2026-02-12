import AppKit

final class RetroConversionStatusView: NSView {
    private let titleField = NSTextField(labelWithString: "Conversion Idle")
    private let detailField = NSTextField(labelWithString: "Ready")
    private let progressBarView = RetroProgressBarView()
    private var animationTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    func start(totalJobs: Int, presetName: String) {
        let total = max(totalJobs, 0)
        titleField.stringValue = "Converting 0/\(total)"
        detailField.stringValue = presetName
        progressBarView.progress = 0
        startAnimation()
    }

    func update(processed: Int, totalJobs: Int, failed: Int, warnings: Int) {
        let total = max(totalJobs, 0)
        let completed = min(max(processed, 0), total)
        let progress = total > 0 ? CGFloat(completed) / CGFloat(total) : 0

        titleField.stringValue = "Converting \(completed)/\(total)"
        detailField.stringValue = "Failed: \(failed) • Warnings: \(warnings)"
        progressBarView.progress = progress
    }

    func finish(totalJobs: Int, success: Int, failed: Int, warnings: Int) {
        let total = max(totalJobs, 0)
        progressBarView.progress = total > 0 ? 1 : 0
        titleField.stringValue = failed > 0 ? "Conversion Finished (Issues)" : "Conversion Finished"
        detailField.stringValue = "Success: \(success) • Failed: \(failed) • Warnings: \(warnings)"
        stopAnimation()
    }

    func setIdle(message: String) {
        titleField.stringValue = "Conversion Idle"
        detailField.stringValue = message
        progressBarView.progress = 0
        stopAnimation()
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = ClassicTheme.chromeStroke.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.78).cgColor

        titleField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = ClassicTheme.accentShadow

        detailField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detailField.textColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        detailField.lineBreakMode = .byTruncatingTail

        progressBarView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(progressBarView)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            progressBarView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 5),
            progressBarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            progressBarView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressBarView.heightAnchor.constraint(equalToConstant: 14),

            detailField.topAnchor.constraint(equalTo: progressBarView.bottomAnchor, constant: 4),
            detailField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    private func startAnimation() {
        progressBarView.isAnimating = true
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.progressBarView.advanceAnimationPhase()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopAnimation() {
        progressBarView.isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

private final class RetroProgressBarView: NSView {
    var progress: CGFloat = 0 {
        didSet {
            progress = max(0, min(progress, 1))
            needsDisplay = true
        }
    }

    var isAnimating: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    private var phase: CGFloat = 0

    override var isOpaque: Bool {
        false
    }

    func advanceAnimationPhase() {
        phase = (phase + 2.5).truncatingRemainder(dividingBy: 14)
        if isAnimating {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 3.5, yRadius: 3.5)

        NSColor(calibratedWhite: 0.86, alpha: 0.95).setFill()
        trackPath.fill()

        ClassicTheme.chromeStroke.withAlphaComponent(0.9).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        guard progress > 0 else {
            return
        }

        let fillWidth = trackRect.width * progress
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3.5, yRadius: 3.5)

        if let gradient = NSGradient(colors: [
            ClassicTheme.accentHighlight,
            ClassicTheme.accentYellow,
            ClassicTheme.accentShadow
        ]) {
            gradient.draw(in: fillPath, angle: -90)
        } else {
            ClassicTheme.accentYellow.setFill()
            fillPath.fill()
        }

        if isAnimating {
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()

            let stripeStep: CGFloat = 8
            let stripePath = NSBezierPath()
            for x in stride(from: fillRect.minX - fillRect.height + phase, through: fillRect.maxX + fillRect.height, by: stripeStep) {
                stripePath.move(to: NSPoint(x: x, y: fillRect.minY))
                stripePath.line(to: NSPoint(x: x + fillRect.height, y: fillRect.maxY))
            }
            stripePath.lineWidth = 1
            NSColor.white.withAlphaComponent(0.3).setStroke()
            stripePath.stroke()

            let pulseCenterX = min(fillRect.maxX - 4, trackRect.maxX - 4)
            let pulseAlpha = 0.5 + 0.5 * sin(phase / 14 * .pi * 2)
            let pulseRect = NSRect(x: pulseCenterX - 3, y: fillRect.midY - 3, width: 6, height: 6)
            let pulsePath = NSBezierPath(ovalIn: pulseRect)
            NSColor.white.withAlphaComponent(pulseAlpha).setFill()
            pulsePath.fill()

            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
