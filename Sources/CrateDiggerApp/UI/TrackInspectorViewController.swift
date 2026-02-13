import AppKit
import CrateDiggerCore

private enum ArtworkZoomMode {
    case fitWidth
    case fitHeight
    case oneToOne
}

final class TrackInspectorViewController: NSViewController {
    private let titleField = NSTextField(labelWithString: "Select a track")
    private let artistField = NSTextField(labelWithString: "")
    private let albumField = NSTextField(labelWithString: "")
    private let detailsField = NSTextField(labelWithString: "")
    private let technicalField = NSTextField(labelWithString: "")
    private let artworkInfoField = NSTextField(labelWithString: "")

    private let zoomControl = NSSegmentedControl(labels: ["Fit", "1x"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let artworkContainer = NSView()
    private let imageView = NSImageView()
    private let placeholderField = NSTextField(labelWithString: "No Artwork")

    private var currentImage: NSImage?
    private var zoomMode: ArtworkZoomMode = .fitWidth
    private var nextFitMode: ArtworkZoomMode = .fitWidth
    private var artworkPreviewSheet: NSWindow?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ModernRetroTheme.surfaceBase.cgColor

        configureTextFields()
        configureArtworkView()

        zoomControl.segmentStyle = .smallSquare
        zoomControl.controlSize = .small
        zoomControl.selectedSegment = 0
        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged)

        let topMetadataStack = NSStackView(views: [titleField, artistField, albumField, detailsField, technicalField, artworkInfoField])
        topMetadataStack.orientation = .vertical
        topMetadataStack.spacing = 5
        topMetadataStack.alignment = .leading
        topMetadataStack.setContentHuggingPriority(.required, for: .vertical)
        topMetadataStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let headerStack = NSStackView(views: [zoomControl])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY

        let contentStack = NSStackView(views: [topMetadataStack, headerStack, scrollView])
        contentStack.orientation = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
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
        technicalField.stringValue = technicalSummary(for: loadedTrack)

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
            zoomMode = .fitWidth
            nextFitMode = .fitWidth
            updateZoomControlUI()
            applyZoom()
        } else {
            currentImage = nil
            imageView.image = nil
            placeholderField.isHidden = false
            zoomControl.isEnabled = false
            zoomMode = .fitWidth
            nextFitMode = .fitWidth
            updateZoomControlUI()
            updateEmptyArtworkLayout()
        }
    }

    private func configureTextFields() {
        titleField.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        artistField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        albumField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        detailsField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        technicalField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        artworkInfoField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        titleField.textColor = ModernRetroTheme.textPrimary
        detailsField.textColor = ModernRetroTheme.textSecondary
        technicalField.textColor = ModernRetroTheme.textSecondary
        artistField.textColor = ModernRetroTheme.textPrimary
        albumField.textColor = ModernRetroTheme.textPrimary
        artworkInfoField.textColor = ModernRetroTheme.textSecondary

        [titleField, artistField, albumField, detailsField, artworkInfoField].forEach {
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 1
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        technicalField.lineBreakMode = .byWordWrapping
        technicalField.maximumNumberOfLines = 2
        technicalField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureArtworkView() {
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .legacy
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = ModernRetroTheme.surfaceElevated.cgColor
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

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true

        let imageClick = NSClickGestureRecognizer(target: self, action: #selector(artworkClicked))
        imageView.addGestureRecognizer(imageClick)

        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.textColor = ModernRetroTheme.textSecondary

        artworkContainer.addSubview(imageView)
        artworkContainer.addSubview(placeholderField)

        NSLayoutConstraint.activate([
            placeholderField.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            placeholderField.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            artworkContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            artworkContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])

        scrollView.documentView = artworkContainer
    }

    private func showNoSelectionState() {
        titleField.stringValue = "Select a track"
        artistField.stringValue = ""
        albumField.stringValue = ""
        detailsField.stringValue = ""
        technicalField.stringValue = ""
        artworkInfoField.stringValue = ""

        currentImage = nil
        imageView.image = nil
        placeholderField.isHidden = false
        zoomControl.isEnabled = false
        zoomMode = .fitWidth
        nextFitMode = .fitWidth
        updateZoomControlUI()
        dismissArtworkPreviewIfNeeded()
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
        guard zoomControl.isEnabled else { return }

        if zoomControl.selectedSegment == 0 {
            zoomMode = nextFitMode
            nextFitMode = (nextFitMode == .fitWidth) ? .fitHeight : .fitWidth
        } else {
            zoomMode = .oneToOne
            nextFitMode = .fitWidth
        }

        updateZoomControlUI()
        applyZoom()
    }

    @objc private func artworkClicked() {
        guard zoomMode == .oneToOne, currentImage != nil else {
            return
        }
        presentArtworkPreviewSheet()
    }

    @objc private func dismissArtworkPreviewFromGesture() {
        dismissArtworkPreviewIfNeeded()
    }

    private func updateZoomControlUI() {
        if zoomMode == .oneToOne {
            zoomControl.selectedSegment = 1
            zoomControl.setToolTip("1x (100%)", forSegment: 1)
            zoomControl.setToolTip("Fit", forSegment: 0)
            return
        }

        zoomControl.selectedSegment = 0
        let fitTip = zoomMode == .fitWidth ? "Fit Width (click Fit again for Height)" : "Fit Height (click Fit again for Width)"
        zoomControl.setToolTip(fitTip, forSegment: 0)
        zoomControl.setToolTip("1x (100%)", forSegment: 1)
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

        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else {
            return
        }

        let zoomScale: CGFloat
        switch zoomMode {
        case .fitWidth:
            zoomScale = max(viewport.width / naturalSize.width, 0.05)
        case .fitHeight:
            zoomScale = max(viewport.height / naturalSize.height, 0.05)
        case .oneToOne:
            zoomScale = 1
        }

        let drawnSize = CGSize(width: naturalSize.width * zoomScale, height: naturalSize.height * zoomScale)
        imageView.frame = NSRect(origin: .zero, size: drawnSize)

        let containerSize = CGSize(
            width: max(drawnSize.width, viewport.width),
            height: max(drawnSize.height, viewport.height)
        )
        container.frame = NSRect(origin: .zero, size: containerSize)

        let x = max((containerSize.width - drawnSize.width) / 2, 0)
        let y = max((containerSize.height - drawnSize.height) / 2, 0)
        imageView.frame.origin = NSPoint(x: x, y: y)
    }

    private func updateEmptyArtworkLayout() {
        let viewport = scrollView.contentView.bounds.size
        let containerSize = CGSize(
            width: max(viewport.width, 280),
            height: max(viewport.height, 220)
        )
        artworkContainer.frame = NSRect(origin: .zero, size: containerSize)
        imageView.frame = NSRect(origin: .zero, size: .zero)
    }

    private func presentArtworkPreviewSheet() {
        guard artworkPreviewSheet == nil else { return }
        guard let image = currentImage else { return }
        guard let hostWindow = view.window else { return }

        let screenBounds = hostWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let maxWidth = max(420, floor(screenBounds.width * 0.82))
        let maxHeight = max(360, floor(screenBounds.height * 0.82))
        let sheetWidth = min(maxWidth, max(image.size.width + 44, 420))
        let sheetHeight = min(maxHeight, max(image.size.height + 44, 360))

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Artwork Preview"
        sheet.titlebarAppearsTransparent = true
        sheet.standardWindowButton(.closeButton)?.isHidden = true
        sheet.isReleasedWhenClosed = false
        sheet.backgroundColor = NSColor.black.withAlphaComponent(0.9)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor

        let previewScroll = NSScrollView()
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = false
        previewScroll.borderType = .noBorder

        let previewContainer = NSView(frame: NSRect(origin: .zero, size: image.size))
        let previewImage = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        previewImage.image = image
        previewImage.imageScaling = .scaleNone
        previewContainer.addSubview(previewImage)
        previewScroll.documentView = previewContainer

        root.addSubview(previewScroll)
        NSLayoutConstraint.activate([
            previewScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            previewScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        let dismissGesture = NSClickGestureRecognizer(target: self, action: #selector(dismissArtworkPreviewFromGesture))
        root.addGestureRecognizer(dismissGesture)
        previewScroll.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismissArtworkPreviewFromGesture)))
        previewContainer.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismissArtworkPreviewFromGesture)))

        sheet.contentView = root
        artworkPreviewSheet = sheet
        hostWindow.beginSheet(sheet)
    }

    private func dismissArtworkPreviewIfNeeded() {
        guard let sheet = artworkPreviewSheet else { return }
        if let hostWindow = view.window, hostWindow.attachedSheet === sheet {
            hostWindow.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
            sheet.close()
        }
        artworkPreviewSheet = nil
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

    private func technicalSummary(for loadedTrack: LoadedTrack) -> String {
        let track = loadedTrack.track
        let format = track.formatName ?? track.fileURL.pathExtension.uppercased()
        let bitRate = track.bitrateKbps.map { "\($0) kbps" } ?? "Unknown"
        let sampleRate = track.sampleRateHz.map { "\($0) Hz" } ?? "Unknown"
        let year = track.year.map(String.init) ?? "Unknown"
        let totalTracks = track.trackTotal.map(String.init) ?? "Unknown"
        return "Format: \(format) • Bitrate: \(bitRate) • Sample: \(sampleRate) • Year: \(year) • Tracks: \(totalTracks)"
    }
}
