import AppKit
import CrateDiggerCore
import QuartzCore

final class AquaLCDView: NSView {
    enum LCDBarMode {
        case hidden
        case conversion(progress: Double, text: String, tone: ModernRetroTheme.StatusTone)
        case timeline(progress: Double, text: String?, tone: ModernRetroTheme.StatusTone)
    }

    private enum LayerName {
        static let container = "ModernLCD.Container"
        static let innerGlow = "ModernLCD.InnerGlow"
        static let topEdge = "ModernLCD.TopEdge"
        static let laneTrack = "ModernLCD.LaneTrack"
        static let laneFill = "ModernLCD.LaneFill"
        static let laneShimmer = "ModernLCD.LaneShimmer"
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let barContainer = NSView()
    private let barTextLabel = NSTextField(labelWithString: "")

    private var currentTrack: LoadedTrack?
    private var primaryStatusOverride: String?
    private var secondaryStatusOverride: String?
    private var secondaryTone: ModernRetroTheme.StatusTone = .neutral

    private var barMode: LCDBarMode = .hidden
    private var animateNextBarTransition = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 460, height: 56)
    }

    func updateTrack(_ loadedTrack: LoadedTrack?) {
        currentTrack = loadedTrack
        render()
    }

    func setPrimaryStatus(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        primaryStatusOverride = (trimmed?.isEmpty == false) ? trimmed : nil
        render()
    }

    func setSecondaryStatus(_ text: String?) {
        setSecondaryStatus(text, tone: .neutral)
    }

    func setSecondaryStatus(_ text: String?, tone: ModernRetroTheme.StatusTone) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        secondaryStatusOverride = (trimmed?.isEmpty == false) ? trimmed : nil
        secondaryTone = tone
        render()
    }

    func setBarMode(_ mode: LCDBarMode, animated: Bool) {
        barMode = mode
        animateNextBarTransition = animated
        render()
    }

    override func layout() {
        super.layout()
        updateOuterLayerFrames()
        updateBarLayers(animated: false)
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        buildOuterLayers()

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = ModernRetroTheme.textPrimary
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = ModernRetroTheme.textSecondary
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        barContainer.translatesAutoresizingMaskIntoConstraints = false
        barContainer.wantsLayer = true
        barContainer.layer?.cornerRadius = 5
        barContainer.layer?.masksToBounds = true

        barTextLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        barTextLabel.alignment = .center
        barTextLabel.lineBreakMode = .byTruncatingTail
        barTextLabel.maximumNumberOfLines = 1
        barTextLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(barContainer)
        barContainer.addSubview(barTextLabel)
        buildBarLayers()

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            barContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            barContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            barContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            barContainer.heightAnchor.constraint(equalToConstant: 14),

            barTextLabel.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor, constant: 6),
            barTextLabel.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor, constant: -6),
            barTextLabel.centerYAnchor.constraint(equalTo: barContainer.centerYAnchor)
        ])

        render()
    }

    private func buildOuterLayers() {
        guard let rootLayer = layer else { return }

        let container = CAGradientLayer()
        container.name = LayerName.container
        container.colors = [
            NSColor.white.withAlphaComponent(0.52).cgColor,
            ModernRetroTheme.surfaceElevated.withAlphaComponent(0.96).cgColor,
            NSColor.white.withAlphaComponent(0.74).cgColor
        ]
        container.locations = [0, 0.52, 1]
        container.cornerRadius = 13
        container.borderWidth = 1
        container.borderColor = ModernRetroTheme.separator.withAlphaComponent(0.5).cgColor
        container.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        container.shadowOpacity = 0.22
        container.shadowRadius = 5
        container.shadowOffset = CGSize(width: 0, height: -1)
        rootLayer.addSublayer(container)

        let innerGlow = CAGradientLayer()
        innerGlow.name = LayerName.innerGlow
        innerGlow.colors = [
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.clear.cgColor
        ]
        innerGlow.locations = [0, 1]
        innerGlow.cornerRadius = 11.5
        container.addSublayer(innerGlow)

        let topEdge = CALayer()
        topEdge.name = LayerName.topEdge
        topEdge.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        container.addSublayer(topEdge)

        updateOuterLayerFrames()
    }

    private func buildBarLayers() {
        guard let laneLayer = barContainer.layer else { return }

        let track = CALayer()
        track.name = LayerName.laneTrack
        track.backgroundColor = ModernRetroTheme.separator.withAlphaComponent(0.28).cgColor
        track.cornerRadius = 5
        track.borderWidth = 1
        track.borderColor = ModernRetroTheme.separator.withAlphaComponent(0.35).cgColor
        laneLayer.addSublayer(track)

        let fill = CALayer()
        fill.name = LayerName.laneFill
        fill.backgroundColor = ModernRetroTheme.accentInfo.withAlphaComponent(0.9).cgColor
        fill.cornerRadius = 5
        track.addSublayer(fill)

        let shimmer = CAGradientLayer()
        shimmer.name = LayerName.laneShimmer
        shimmer.colors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.38).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        shimmer.locations = [0.2, 0.5, 0.8]
        fill.addSublayer(shimmer)
    }

    private func updateOuterLayerFrames() {
        guard let container = layer?.sublayers?.first(where: { $0.name == LayerName.container }) as? CAGradientLayer else {
            return
        }

        container.frame = bounds.insetBy(dx: 1, dy: 2)

        if let innerGlow = container.sublayers?.first(where: { $0.name == LayerName.innerGlow }) as? CAGradientLayer {
            innerGlow.frame = container.bounds.insetBy(dx: 2, dy: 2)
        }

        if let topEdge = container.sublayers?.first(where: { $0.name == LayerName.topEdge }) {
            topEdge.frame = CGRect(x: 11, y: container.bounds.height - 2, width: max(container.bounds.width - 22, 0), height: 1)
        }
    }

    private func updateBarLayers(animated: Bool) {
        guard let track = barContainer.layer?.sublayers?.first(where: { $0.name == LayerName.laneTrack }),
              let fill = track.sublayers?.first(where: { $0.name == LayerName.laneFill }),
              let shimmer = fill.sublayers?.first(where: { $0.name == LayerName.laneShimmer }) as? CAGradientLayer
        else {
            return
        }

        track.frame = barContainer.bounds

        guard let payload = activeBarPayload else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = CGRect(x: 0, y: 0, width: 0, height: track.bounds.height)
            shimmer.frame = fill.bounds
            CATransaction.commit()
            stopShimmerAnimation(shimmer)
            return
        }

        let clampedProgress = CGFloat(max(0.0, min(payload.progress, 1.0)))
        let toneColor = ModernRetroTheme.statusColor(for: payload.tone)
        track.borderColor = toneColor.withAlphaComponent(0.3).cgColor
        track.backgroundColor = toneColor.withAlphaComponent(0.14).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 0.22 : 0.0)
        fill.backgroundColor = toneColor.withAlphaComponent(0.88).cgColor
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * clampedProgress, height: track.bounds.height)
        shimmer.frame = fill.bounds
        CATransaction.commit()

        if fill.bounds.width > 2 {
            startShimmerAnimation(shimmer)
        } else {
            stopShimmerAnimation(shimmer)
        }
    }

    private func startShimmerAnimation(_ shimmer: CAGradientLayer) {
        let animationKey = "ModernLCD.Shimmer"
        guard shimmer.animation(forKey: animationKey) == nil else { return }

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -20
        animation.toValue = 20
        animation.duration = 0.75
        animation.repeatCount = .infinity
        shimmer.add(animation, forKey: animationKey)
    }

    private func stopShimmerAnimation(_ shimmer: CAGradientLayer) {
        shimmer.removeAnimation(forKey: "ModernLCD.Shimmer")
    }

    private var activeBarPayload: (progress: Double, text: String, tone: ModernRetroTheme.StatusTone)? {
        switch barMode {
        case .hidden:
            return nil
        case .conversion(let progress, let text, let tone):
            return (progress, text, tone)
        case .timeline(let progress, let text, let tone):
            let fallbackText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayText = (fallbackText?.isEmpty == false) ? fallbackText ?? "Timeline" : "Timeline"
            return (progress, displayText, tone)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func render() {
        if let primaryStatusOverride {
            titleLabel.stringValue = primaryStatusOverride
        } else if let track = currentTrack?.track {
            titleLabel.stringValue = track.title
        } else {
            titleLabel.stringValue = "Ready to Load Tracks"
        }

        if let payload = activeBarPayload {
            barContainer.isHidden = false
            detailLabel.isHidden = true
            barTextLabel.stringValue = payload.text
            switch payload.tone {
            case .warning:
                barTextLabel.textColor = ModernRetroTheme.textPrimary
            case .neutral:
                barTextLabel.textColor = ModernRetroTheme.textSecondary
            case .info, .success, .error:
                barTextLabel.textColor = NSColor.white.withAlphaComponent(0.95)
            }
            updateBarLayers(animated: animateNextBarTransition)
            animateNextBarTransition = false
            return
        }

        barContainer.isHidden = true
        detailLabel.isHidden = false
        barTextLabel.stringValue = ""
        updateBarLayers(animated: false)
        animateNextBarTransition = false

        if let secondaryStatusOverride {
            detailLabel.stringValue = secondaryStatusOverride
            detailLabel.textColor = ModernRetroTheme.statusColor(for: secondaryTone)
            return
        }

        detailLabel.textColor = ModernRetroTheme.textSecondary
        if let track = currentTrack?.track {
            let artist = track.artist.isEmpty ? "Unknown Artist" : track.artist
            let album = track.album.isEmpty ? "Unknown Album" : track.album
            detailLabel.stringValue = "\(artist) • \(album) • \(formatDuration(track.durationSeconds))"
        } else {
            detailLabel.stringValue = "Load audio to begin conversion"
        }
    }
}
