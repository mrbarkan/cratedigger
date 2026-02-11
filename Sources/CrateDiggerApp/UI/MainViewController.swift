import AppKit
import CrateDiggerCore

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let artworkService = ArtworkService()
    private lazy var libraryScanService = LibraryScanService(artworkService: artworkService)

    private var conversionService: ConversionService?
    private var conversionServiceInitializationError: Error?

    private var loadedTracks: [LoadedTrack] = []
    private var currentLibraryRoot: URL?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preserveStructureCheckbox = NSButton(checkboxWithTitle: "Preserve folder structure", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "Load a folder to begin")
    private let convertButton = NSButton(title: "Convert Selected", target: nil, action: nil)

    private let inspectorViewController = TrackInspectorViewController()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addChild(inspectorViewController)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        configureLeftPane(in: leftContainer)

        splitView.addArrangedSubview(leftContainer)
        splitView.addArrangedSubview(inspectorViewController.view)

        inspectorViewController.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorViewController.view.widthAnchor.constraint(equalToConstant: 420).isActive = true

        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])

        configureConversionPresets()
        configureServices()
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        loadTracks(from: folderURL)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        loadedTracks.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        52
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TrackCellView")

        let cell: TrackCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? TrackCellView {
            cell = reusable
        } else {
            cell = TrackCellView(frame: .zero)
            cell.identifier = identifier
        }

        let loadedTrack = loadedTracks[row]
        let thumbnail = loadedTrack.track.artworkHash.flatMap {
            artworkService.generateThumbnail(artworkHash: $0, size: CGSize(width: 36, height: 36))
        }

        cell.configure(track: loadedTrack.track, thumbnail: thumbnail)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, loadedTracks.indices.contains(tableView.selectedRow) else {
            inspectorViewController.update(with: nil)
            convertButton.isEnabled = false
            return
        }

        inspectorViewController.update(with: loadedTracks[tableView.selectedRow])
        convertButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    private func configureLeftPane(in container: NSView) {
        let openButton = NSButton(title: "Open Folder", target: self, action: #selector(openFolderAction))

        let presetLabel = NSTextField(labelWithString: "Convert preset:")

        preserveStructureCheckbox.state = .on

        convertButton.target = self
        convertButton.action = #selector(convertSelectedTracks)
        convertButton.isEnabled = false

        let controlsStack = NSStackView(views: [openButton, presetLabel, presetPopUp, preserveStructureCheckbox, convertButton])
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 10

        let trackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrackColumn"))
        trackColumn.title = "Tracks"
        tableView.addTableColumn(trackColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        statusField.textColor = .secondaryLabelColor
        statusField.font = NSFont.systemFont(ofSize: 12)

        let contentStack = NSStackView(views: [controlsStack, scrollView, statusField])
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    private func configureConversionPresets() {
        presetPopUp.removeAllItems()

        for preset in ConversionPreset.defaultPresets {
            presetPopUp.addItem(withTitle: preset.name)
            presetPopUp.lastItem?.representedObject = preset.id
        }

        if let firstIPodPresetIndex = ConversionPreset.defaultPresets.firstIndex(where: { $0.deviceProfile == .ipodLegacySafe }) {
            presetPopUp.selectItem(at: firstIPodPresetIndex)
        }
    }

    private func configureServices() {
        do {
            conversionService = try ConversionService(artworkPreparer: artworkService)
        } catch {
            conversionServiceInitializationError = error
            statusField.stringValue = "ffmpeg was not found. Loading and artwork preview work; conversion is unavailable."
        }
    }

    private func loadTracks(from folderURL: URL) {
        currentLibraryRoot = folderURL
        statusField.stringValue = "Scanning \(folderURL.lastPathComponent)..."
        convertButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let tracks = self.libraryScanService.scanFolder(folderURL)

            DispatchQueue.main.async {
                self.loadedTracks = tracks
                self.tableView.reloadData()

                if tracks.isEmpty {
                    self.statusField.stringValue = "No supported audio files found"
                    self.inspectorViewController.update(with: nil)
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.statusField.stringValue = "Loaded \(tracks.count) tracks"
                    self.convertButton.isEnabled = true
                }
            }
        }
    }

    @objc private func openFolderAction() {
        openFolder()
    }

    @objc private func convertSelectedTracks() {
        guard let conversionService else {
            showAlert(
                title: "Conversion Unavailable",
                message: conversionServiceInitializationError?.localizedDescription ?? "ffmpeg is not configured."
            )
            return
        }

        let selectedTracks = tableView.selectedRowIndexes.compactMap { index in
            loadedTracks.indices.contains(index) ? loadedTracks[index] : nil
        }

        guard !selectedTracks.isEmpty else {
            showAlert(title: "No Selection", message: "Select one or more tracks first.")
            return
        }

        guard let presetID = presetPopUp.selectedItem?.representedObject as? String,
              let preset = ConversionPreset.preset(withID: presetID)
        else {
            showAlert(title: "Missing Preset", message: "Choose a conversion preset.")
            return
        }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false

        guard destinationPanel.runModal() == .OK, let destinationFolder = destinationPanel.url else {
            return
        }

        var jobs: [ConversionJob] = []
        jobs.reserveCapacity(selectedTracks.count)

        for loaded in selectedTracks {
            let outputURL = destinationURL(for: loaded.track, preset: preset, destinationRoot: destinationFolder)
            let job = ConversionJob(sourceURL: loaded.track.fileURL, destinationURL: outputURL, metadata: loaded.metadata)
            jobs.append(job)
        }

        do {
            conversionService.clearQueue()
            _ = try conversionService.enqueue(jobs, presetID: preset.id, deviceProfile: preset.deviceProfile)
        } catch {
            showAlert(title: "Queue Failed", message: error.localizedDescription)
            return
        }

        statusField.stringValue = "Converting \(jobs.count) file(s) with \(preset.name)..."
        convertButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let results = conversionService.runQueuedJobs()

            DispatchQueue.main.async {
                let completed = results.filter { $0.status == .completed }.count
                let failed = results.filter { $0.status == .failed }.count
                let warnings = results.compactMap { $0.warning }

                self.statusField.stringValue = "Conversion complete. Success: \(completed), Failed: \(failed), Warnings: \(warnings.count)."
                self.convertButton.isEnabled = true

                var message = "Completed: \(completed)\nFailed: \(failed)"
                if !warnings.isEmpty {
                    message += "\nWarnings:\n- " + warnings.prefix(5).joined(separator: "\n- ")
                }

                if failed > 0 {
                    let failureLogs = results
                        .filter { $0.status == .failed }
                        .prefix(3)
                        .map { $0.log.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .joined(separator: "\n\n")

                    if !failureLogs.isEmpty {
                        message += "\n\nFailure details:\n\(failureLogs)"
                    }
                }

                self.showAlert(title: "Conversion Finished", message: message)
            }
        }
    }

    private func destinationURL(for track: AudioTrack, preset: ConversionPreset, destinationRoot: URL) -> URL {
        let sourceDirectory = track.fileURL.deletingLastPathComponent()
        var outputDirectory = destinationRoot

        if preserveStructureCheckbox.state == .on,
           let root = currentLibraryRoot {
            let rootComponents = root.standardizedFileURL.pathComponents
            let sourceComponents = sourceDirectory.standardizedFileURL.pathComponents

            if sourceComponents.starts(with: rootComponents) {
                for component in sourceComponents.dropFirst(rootComponents.count) {
                    outputDirectory.appendPathComponent(component, isDirectory: true)
                }
            }
        }

        let baseName = track.fileURL.deletingPathExtension().lastPathComponent
        return outputDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(preset.outputExtension)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

private final class TrackCellView: NSTableCellView {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(track: AudioTrack, thumbnail: NSImage?) {
        artworkView.image = thumbnail ?? Self.placeholderArtwork

        titleLabel.stringValue = track.title
        let artist = track.artist.isEmpty ? "Unknown Artist" : track.artist
        let album = track.album.isEmpty ? "Unknown Album" : track.album
        detailLabel.stringValue = "\(artist) • \(album) • \(formatDuration(track.durationSeconds))"
    }

    private func configure() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleAxesIndependently
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 3
        artworkView.layer?.masksToBounds = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(artworkView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 36),
            artworkView.heightAnchor.constraint(equalToConstant: 36),

            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static var placeholderArtwork: NSImage {
        let size = NSSize(width: 36, height: 36)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(white: 0.9, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let note = "A" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.gray
        ]
        let noteSize = note.size(withAttributes: attrs)
        note.draw(
            at: NSPoint(
                x: (size.width - noteSize.width) / 2,
                y: (size.height - noteSize.height) / 2 - 1
            ),
            withAttributes: attrs
        )

        image.unlockFocus()
        return image
    }
}
