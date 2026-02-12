import AppKit
import CrateDiggerCore

final class TrackInspectorViewController: NSViewController {
    private let titleField = NSTextField(labelWithString: "Select a track")
    private let artistField = NSTextField(labelWithString: "")
    private let albumField = NSTextField(labelWithString: "")
    private let detailsField = NSTextField(labelWithString: "")
    private let artworkInfoField = NSTextField(labelWithString: "")

    private let zoomControl = NSSegmentedControl(labels: ["Fit", "1x", "2x"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let artworkContainer = NSView()
    private let imageView = NSImageView()
    private let placeholderField = NSTextField(labelWithString: "No Artwork")

    private var currentImage: NSImage?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView()
        ClassicTheme.applyPinstripe(to: view)

        configureTextFields()
        configureArtworkView()

        zoomControl.segmentStyle = .smallSquare
        zoomControl.controlSize = .small
        zoomControl.selectedSegment = 0
        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged)

        let topMetadataStack = NSStackView(views: [titleField, artistField, albumField, detailsField, artworkInfoField])
        topMetadataStack.orientation = .vertical
        topMetadataStack.spacing = 6
        topMetadataStack.alignment = .leading

        let headerStack = NSStackView(views: [zoomControl])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY

        let contentStack = NSStackView(views: [topMetadataStack, headerStack, scrollView])
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        showNoSelectionState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if currentImage != nil {
            applyZoom()
        } else {
            updateEmptyArtworkLayout()
        }
    }

    func update(with loadedTrack: LoadedTrack?) {
        guard let loadedTrack else {
            showNoSelectionState()
            return
        }

        let track = loadedTrack.track
        titleField.stringValue = track.title
        artistField.stringValue = track.artist.isEmpty ? "Unknown Artist" : track.artist
        albumField.stringValue = track.album.isEmpty ? "Unknown Album" : track.album

        let durationText = formatDuration(track.durationSeconds)
        detailsField.stringValue = "Duration: \(durationText)"

        if let dimensions = track.artworkDimensions,
           let hash = track.artworkHash {
            artworkInfoField.stringValue = "Artwork: \(track.artworkSource.rawValue) • \(dimensions.width)x\(dimensions.height) • \(hash.prefix(12))"
        } else {
            artworkInfoField.stringValue = "Artwork: none"
        }

        if let data = loadedTrack.metadata.artwork?.data,
           let image = NSImage(data: data) {
            currentImage = image
            imageView.image = image
            placeholderField.isHidden = true
            zoomControl.isEnabled = true
            applyZoom()
        } else {
            currentImage = nil
            imageView.image = nil
            placeholderField.isHidden = false
            zoomControl.isEnabled = false
            updateEmptyArtworkLayout()
        }
    }

    private func configureTextFields() {
        titleField.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        artistField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        albumField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        detailsField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        artworkInfoField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        titleField.textColor = ClassicTheme.accentShadow
        detailsField.textColor = ClassicTheme.accentShadow

        [titleField, artistField, albumField, detailsField, artworkInfoField].forEach {
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 1
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    private func configureArtworkView() {
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .legacy
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = ClassicTheme.pinstripeBackground.cgColor
        scrollView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        scrollView.layer?.shadowOpacity = 0.12
        scrollView.layer?.shadowRadius = 4
        scrollView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        imageView.imageScaling = .scaleProportionallyUpOrDown
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.textColor = ClassicTheme.accentShadow

        artworkContainer.addSubview(imageView)
        artworkContainer.addSubview(placeholderField)

        NSLayoutConstraint.activate([
            placeholderField.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            placeholderField.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            artworkContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            artworkContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        scrollView.documentView = artworkContainer
    }

    private func showNoSelectionState() {
        titleField.stringValue = "Select a track"
        artistField.stringValue = ""
        albumField.stringValue = ""
        detailsField.stringValue = ""
        artworkInfoField.stringValue = ""

        currentImage = nil
        imageView.image = nil
        placeholderField.isHidden = false
        zoomControl.isEnabled = false
        updateEmptyArtworkLayout()
    }

    @objc private func contentBoundsChanged() {
        if currentImage != nil {
            applyZoom()
        } else {
            updateEmptyArtworkLayout()
        }
    }

    @objc private func zoomChanged() {
        applyZoom()
    }

    private func applyZoom() {
        guard let image = currentImage,
              let container = scrollView.documentView
        else {
            return
        }

        let naturalSize = image.size
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return
        }

        let zoomScale: CGFloat
        switch zoomControl.selectedSegment {
        case 1:
            zoomScale = 1
        case 2:
            zoomScale = 2
        default:
            let viewport = scrollView.contentView.bounds.size
            let widthScale = viewport.width / naturalSize.width
            let heightScale = viewport.height / naturalSize.height
            zoomScale = max(min(widthScale, heightScale), 0.1)
        }

        let drawnSize = CGSize(width: naturalSize.width * zoomScale, height: naturalSize.height * zoomScale)
        imageView.frame = NSRect(origin: .zero, size: drawnSize)
        container.frame = NSRect(origin: .zero, size: CGSize(
            width: max(drawnSize.width, scrollView.contentView.bounds.width),
            height: max(drawnSize.height, scrollView.contentView.bounds.height)
        ))

        let x = max((container.frame.width - drawnSize.width) / 2, 0)
        let y = max((container.frame.height - drawnSize.height) / 2, 0)
        imageView.frame.origin = NSPoint(x: x, y: y)
    }

    private func updateEmptyArtworkLayout() {
        let viewport = scrollView.contentView.bounds.size
        let containerSize = CGSize(
            width: max(viewport.width, 360),
            height: max(viewport.height, 360)
        )
        artworkContainer.frame = NSRect(origin: .zero, size: containerSize)
        imageView.frame = NSRect(origin: .zero, size: .zero)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
