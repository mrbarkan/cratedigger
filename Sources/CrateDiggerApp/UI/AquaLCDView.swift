import AppKit
import QuartzCore
import CrateDiggerCore

final class AquaLCDView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 420, height: 44)
    }

    func update(with loadedTrack: LoadedTrack?, status: String?) {
        if let track = loadedTrack?.track {
            titleLabel.stringValue = track.title
            let artist = track.artist.isEmpty ? "Unknown Artist" : track.artist
            let album = track.album.isEmpty ? "Unknown Album" : track.album
            let duration = formatDuration(track.durationSeconds)
            detailLabel.stringValue = "\(artist) • \(album) • \(duration)"
        } else if let status, !status.isEmpty {
            titleLabel.stringValue = status
            detailLabel.stringValue = ""
        } else {
            titleLabel.stringValue = "No track selected"
            detailLabel.stringValue = ""
        }
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds
        layer?.sublayers?.dropFirst().forEach { $0.frame = bounds }
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.95)
        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor(calibratedWhite: 0.25, alpha: 0.9)

        [titleLabel, detailLabel].forEach {
            $0.alignment = .center
            $0.lineBreakMode = .byTruncatingTail
        }

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func buildLayers() {
        let base = CAGradientLayer()
        base.colors = [
            ClassicTheme.lcdTop.cgColor,
            ClassicTheme.lcdMid.cgColor,
            ClassicTheme.lcdBottom.cgColor
        ]
        base.locations = [0, 0.55, 1]
        base.cornerRadius = 10
        base.borderColor = ClassicTheme.chromeStroke.withAlphaComponent(0.8).cgColor
        base.borderWidth = 1
        base.shadowColor = NSColor.black.withAlphaComponent(0.2).cgColor
        base.shadowOffset = CGSize(width: 0, height: -1)
        base.shadowRadius = 2
        base.shadowOpacity = 0.4
        base.frame = bounds
        layer?.insertSublayer(base, at: 0)

        let gloss = CAGradientLayer()
        gloss.colors = [
            NSColor.white.withAlphaComponent(0.65).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        gloss.locations = [0, 1]
        gloss.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * 0.45)
        gloss.cornerRadius = 10
        layer?.insertSublayer(gloss, above: base)

        let innerStroke = CALayer()
        innerStroke.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        innerStroke.borderWidth = 1
        innerStroke.cornerRadius = 9.5
        innerStroke.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        layer?.insertSublayer(innerStroke, above: gloss)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
