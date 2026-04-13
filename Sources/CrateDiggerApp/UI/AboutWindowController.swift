import AppKit

final class AboutWindowController: NSWindowController {
    init() {
        let viewController = AboutViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About CrateDigger"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = BrandArtworkPalette.paper
        window.contentViewController = viewController
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AboutViewController: NSViewController {
    private let backgroundView = BrandBackdropView()
    private let cardView = GlassCardView(
        fillColor: NSColor.white.withAlphaComponent(0.74),
        borderColor: BrandArtworkPalette.chrome.withAlphaComponent(0.55)
    )
    private let heroCard = GlassCardView(
        fillColor: NSColor.white.withAlphaComponent(0.54),
        borderColor: BrandArtworkPalette.chrome.withAlphaComponent(0.45),
        cornerRadius: 22
    )
    private let artworkView = BrandArtworkView()
    private let titleLabel = NSTextField(labelWithString: "CrateDigger")
    private let taglineLabel = NSTextField(wrappingLabelWithString: "A modern-retro workstation for scanning, previewing, and cleaning up unruly music libraries.")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Built for the awkward gap between raw folder dumps and a library you actually want to keep.")
    private let versionPill = BrandPillView(
        text: "VERSION",
        fill: BrandArtworkPalette.slate.withAlphaComponent(0.94),
        textColor: BrandArtworkPalette.paper
    )
    private let platformPill = BrandPillView(
        text: "MACOS + APPKIT",
        fill: BrandArtworkPalette.cyan.withAlphaComponent(0.18)
    )
    private let creditsLabel = NSTextField(labelWithString: "Built with Swift, AppKit, and FFmpeg tooling.")
    private let footerLabel = NSTextField(labelWithString: "Icon, splash artwork, and preview assets live in the repo's Branding package.")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = BrandArtworkPalette.paper.cgColor

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        heroCard.translatesAutoresizingMaskIntoConstraints = false
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 38, weight: .black)
        titleLabel.textColor = BrandArtworkPalette.slate

        taglineLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        taglineLabel.textColor = BrandArtworkPalette.slateSoft
        taglineLabel.maximumNumberOfLines = 0

        summaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        summaryLabel.textColor = BrandArtworkPalette.slateSoft.withAlphaComponent(0.92)
        summaryLabel.maximumNumberOfLines = 0

        creditsLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        creditsLabel.textColor = BrandArtworkPalette.slate

        footerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = BrandArtworkPalette.slateSoft

        let eyebrowLabel = NSTextField(labelWithString: "MODERN RETRO AUDIO WORKBENCH")
        eyebrowLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        eyebrowLabel.textColor = BrandArtworkPalette.cyan

        let heroEyebrow = NSTextField(labelWithString: "CRATE SCAN MARK")
        heroEyebrow.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        heroEyebrow.alignment = .center
        heroEyebrow.textColor = BrandArtworkPalette.slateSoft

        let heroCaption = NSTextField(wrappingLabelWithString: "Record crate, vinyl disc, and scan beam combined into one compact Dock mark.")
        heroCaption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        heroCaption.alignment = .center
        heroCaption.textColor = BrandArtworkPalette.slateSoft
        heroCaption.maximumNumberOfLines = 0

        let heroPills = NSStackView(views: [
            BrandPillView(text: "SCAN", fill: BrandArtworkPalette.cyan.withAlphaComponent(0.2)),
            BrandPillView(text: "PREVIEW", fill: BrandArtworkPalette.amber.withAlphaComponent(0.22)),
            BrandPillView(text: "CONVERT", fill: BrandArtworkPalette.coral.withAlphaComponent(0.18))
        ])
        heroPills.orientation = .horizontal
        heroPills.alignment = .centerY
        heroPills.spacing = 8
        heroPills.distribution = .fillProportionally
        heroPills.translatesAutoresizingMaskIntoConstraints = false

        let heroStack = NSStackView(views: [heroEyebrow, artworkView, heroCaption, heroPills])
        heroStack.orientation = .vertical
        heroStack.alignment = .centerX
        heroStack.spacing = 14
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        heroCard.addSubview(heroStack)

        let featureStack = NSStackView(views: [
            BrandFeatureRowView(
                title: "Scan with context",
                description: "Browse mixed folders quickly and understand what is in a library before committing to a cleanup pass.",
                tint: BrandArtworkPalette.cyan
            ),
            BrandFeatureRowView(
                title: "Preview without guessing",
                description: "Artwork, metadata, and playback stay close together so inspection feels fast and tactile.",
                tint: BrandArtworkPalette.amber
            ),
            BrandFeatureRowView(
                title: "Convert cleanly",
                description: "Reshape chaotic source folders into more intentional library destinations without losing track of structure.",
                tint: BrandArtworkPalette.coral
            )
        ])
        featureStack.orientation = .vertical
        featureStack.alignment = .leading
        featureStack.spacing = 14
        featureStack.translatesAutoresizingMaskIntoConstraints = false

        let footerPills = NSStackView(views: [versionPill, platformPill])
        footerPills.orientation = .horizontal
        footerPills.alignment = .centerY
        footerPills.spacing = 10
        footerPills.translatesAutoresizingMaskIntoConstraints = false

        let infoStack = NSStackView(views: [
            eyebrowLabel,
            titleLabel,
            taglineLabel,
            summaryLabel,
            featureStack,
            footerPills,
            creditsLabel,
            footerLabel
        ])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 12
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [heroCard, infoStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 26
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(backgroundView)
        view.addSubview(cardView)
        cardView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),

            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 26),
            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 26),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -26),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -26),

            heroCard.widthAnchor.constraint(equalToConstant: 270),

            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 18),
            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 18),
            heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -18),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -18),

            artworkView.widthAnchor.constraint(equalToConstant: 220),
            artworkView.heightAnchor.constraint(equalToConstant: 220)
        ])

        versionPill.setContentHuggingPriority(.required, for: .horizontal)
        platformPill.setContentHuggingPriority(.required, for: .horizontal)
        heroCard.setContentHuggingPriority(.required, for: .horizontal)
        updateVersionPill()
    }

    private func updateVersionPill() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        versionPill.text = "VERSION \(version) (\(build))"
    }
}
