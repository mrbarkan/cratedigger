import AppKit
import CrateDiggerCore

private enum FolderStructureMode: String, CaseIterable {
    case sourceRelative = "source_relative"
    case flat
    case metadataTemplate = "metadata_template"

    var title: String {
        switch self {
        case .sourceRelative:
            return "Source Relative"
        case .flat:
            return "Flat"
        case .metadataTemplate:
            return "Metadata Template"
        }
    }
}

private enum FolderToken: String, CaseIterable {
    case year
    case artist
    case album

    var title: String {
        switch self {
        case .year:
            return "Year"
        case .artist:
            return "Artist"
        case .album:
            return "Album"
        }
    }
}

private enum TemplateApplyMode: String, CaseIterable {
    case applyAll = "apply_all"
    case reviewPerAlbumPreflight = "review_per_album_preflight"

    var title: String {
        switch self {
        case .applyAll:
            return "Apply to all"
        case .reviewPerAlbumPreflight:
            return "Ask for each album"
        }
    }
}

private enum TemplatePreset: String, CaseIterable {
    case artistYearAlbum
    case yearArtistAlbum
    case artistAlbumYear
    case custom

    var title: String {
        switch self {
        case .artistYearAlbum:
            return "Artist / Year - Album"
        case .yearArtistAlbum:
            return "Year / Artist / Album"
        case .artistAlbumYear:
            return "Artist / Album (Year)"
        case .custom:
            return "Custom Order"
        }
    }

    var defaultTokenOrder: [FolderToken] {
        switch self {
        case .artistYearAlbum:
            return [.artist, .year, .album]
        case .yearArtistAlbum:
            return [.year, .artist, .album]
        case .artistAlbumYear:
            return [.artist, .album, .year]
        case .custom:
            return [.artist, .year, .album]
        }
    }
}

private struct AlbumGroupKey: Hashable {
    let artist: String
    let album: String
    let year: String
}

private struct TemplateConfig {
    let preset: TemplatePreset
    let tokenOrder: [FolderToken]
    let separator: String
}

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let artworkService = ArtworkService()
    private lazy var libraryScanService = LibraryScanService(artworkService: artworkService)

    private var conversionService: ConversionService?
    private var conversionServiceInitializationError: Error?
    private var scanTask: Task<Void, Never>?

    private var loadedTracks: [LoadedTrack] = []
    private var currentLibraryRoot: URL?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let openFolderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    private let batchScopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitratePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sampleRatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderStructurePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let templatePresetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenOrderPopUp1 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenOrderPopUp2 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenOrderPopUp3 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let templateSeparatorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let templateOptionsStack = NSStackView()
    private let customOrderStack = NSStackView()
    private let statusField = NSTextField(labelWithString: "Load a folder to begin")
    private let convertButton = NSButton(title: "Convert Selected", target: nil, action: nil)

    private let inspectorViewController = TrackInspectorViewController()
    private let outputFormats: [OutputFormat] = [.mp3, .aac, .alac, .flac, .wav, .aiff, .ogg, .opus]
    private let bitrateOptions = [-1, 96, 128, 160, 192, 256, 320]
    private let sampleRateOptions = [-1, 32000, 44100, 48000, 96000]
    private let templateSeparatorOptions = [" - ", " ", "_"]
    private let unknownArtist = "Unknown Artist"
    private let unknownAlbum = "Unknown Album"
    private let unknownYear = "Unknown Year"

    private let defaults = UserDefaults.standard
    private let defaultsFolderStructureModeKey = "CrateDigger.folderStructureMode"
    private let defaultsTemplatePresetKey = "CrateDigger.templatePreset"
    private let defaultsTemplateApplyModeKey = "CrateDigger.templateApplyMode"
    private let defaultsTokenOrderKey = "CrateDigger.templateTokenOrder"
    private let defaultsTemplateSeparatorKey = "CrateDigger.templateSeparator"

    deinit {
        scanTask?.cancel()
    }

    override func loadView() {
        view = NSView()
        ClassicTheme.applyPinstripe(to: view)

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

        ClassicTheme.applyPinstripe(to: inspectorViewController.view)
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

        configureConversionOptions()
        configureServices()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        ClassicTheme.updateButtonGradient(openFolderButton)
        ClassicTheme.updateButtonGradient(convertButton)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ClassicRowView()
        rowView.rowIndex = row
        return rowView
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
            updateConvertButtonState()
            return
        }

        inspectorViewController.update(with: loadedTracks[tableView.selectedRow])
        updateConvertButtonState()
    }

    private func configureLeftPane(in container: NSView) {
        let batchScopeLabel = NSTextField(labelWithString: "Batch:")
        let formatLabel = NSTextField(labelWithString: "Format:")
        let bitrateLabel = NSTextField(labelWithString: "Bitrate:")
        let sampleRateLabel = NSTextField(labelWithString: "Sample Rate:")
        let folderStructureLabel = NSTextField(labelWithString: "Folder Structure:")
        let applyModeLabel = NSTextField(labelWithString: "Apply Mode:")
        let templatePresetLabel = NSTextField(labelWithString: "Template:")
        let tokenOrderLabel = NSTextField(labelWithString: "Token Order:")
        let separatorLabel = NSTextField(labelWithString: "Joiner:")

        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderAction)
        ClassicTheme.applyAquaAccent(to: openFolderButton)

        convertButton.target = self
        convertButton.action = #selector(convertSelectedTracks)
        convertButton.isEnabled = false
        convertButton.title = "Convert"
        ClassicTheme.applyAquaAccent(to: convertButton)

        batchScopePopUp.target = self
        batchScopePopUp.action = #selector(batchScopeChanged)

        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)

        folderStructurePopUp.target = self
        folderStructurePopUp.action = #selector(folderStructureChanged)

        applyModePopUp.target = self
        applyModePopUp.action = #selector(applyModeChanged)

        templatePresetPopUp.target = self
        templatePresetPopUp.action = #selector(templatePresetChanged)

        tokenOrderPopUp1.target = self
        tokenOrderPopUp1.action = #selector(customTokenOrderChanged)
        tokenOrderPopUp2.target = self
        tokenOrderPopUp2.action = #selector(customTokenOrderChanged)
        tokenOrderPopUp3.target = self
        tokenOrderPopUp3.action = #selector(customTokenOrderChanged)

        templateSeparatorPopUp.target = self
        templateSeparatorPopUp.action = #selector(templateSeparatorChanged)

        [
            batchScopePopUp,
            formatPopUp,
            bitratePopUp,
            sampleRatePopUp,
            folderStructurePopUp,
            applyModePopUp,
            templatePresetPopUp,
            tokenOrderPopUp1,
            tokenOrderPopUp2,
            tokenOrderPopUp3,
            templateSeparatorPopUp
        ].forEach(stylePopUp)

        let topControls = NSStackView(views: [openFolderButton, batchScopeLabel, batchScopePopUp, convertButton])
        topControls.orientation = .horizontal
        topControls.alignment = .centerY
        topControls.spacing = 10

        let conversionControls = NSStackView(views: [formatLabel, formatPopUp, bitrateLabel, bitratePopUp, sampleRateLabel, sampleRatePopUp])
        conversionControls.orientation = .horizontal
        conversionControls.alignment = .centerY
        conversionControls.spacing = 10

        let folderControls = NSStackView(views: [folderStructureLabel, folderStructurePopUp, applyModeLabel, applyModePopUp])
        folderControls.orientation = .horizontal
        folderControls.alignment = .centerY
        folderControls.spacing = 10

        let templatePresetControls = NSStackView(views: [templatePresetLabel, templatePresetPopUp, separatorLabel, templateSeparatorPopUp])
        templatePresetControls.orientation = .horizontal
        templatePresetControls.alignment = .centerY
        templatePresetControls.spacing = 10

        customOrderStack.orientation = .horizontal
        customOrderStack.alignment = .centerY
        customOrderStack.spacing = 10
        customOrderStack.addArrangedSubview(tokenOrderLabel)
        customOrderStack.addArrangedSubview(tokenOrderPopUp1)
        customOrderStack.addArrangedSubview(tokenOrderPopUp2)
        customOrderStack.addArrangedSubview(tokenOrderPopUp3)

        templateOptionsStack.orientation = .vertical
        templateOptionsStack.alignment = .leading
        templateOptionsStack.spacing = 6
        templateOptionsStack.addArrangedSubview(templatePresetControls)
        templateOptionsStack.addArrangedSubview(customOrderStack)

        let trackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrackColumn"))
        trackColumn.title = "Tracks"
        tableView.addTableColumn(trackColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = ClassicTheme.chromeStroke.withAlphaComponent(0.45)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = ClassicTheme.pinstripeBackground.cgColor

        statusField.textColor = ClassicTheme.accentShadow
        statusField.font = NSFont.systemFont(ofSize: 12)

        let contentStack = NSStackView(views: [topControls, conversionControls, folderControls, templateOptionsStack, scrollView, statusField])
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

    private func stylePopUp(_ popUp: NSPopUpButton) {
        popUp.bezelStyle = .texturedRounded
        popUp.controlSize = .small
        popUp.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    private func configureConversionOptions() {
        batchScopePopUp.removeAllItems()
        batchScopePopUp.addItems(withTitles: ["Selected Tracks", "All Loaded Tracks"])
        batchScopePopUp.selectItem(at: 0)

        formatPopUp.removeAllItems()
        for format in outputFormats {
            formatPopUp.addItem(withTitle: displayName(for: format))
            formatPopUp.lastItem?.representedObject = format.rawValue
        }
        if let defaultIndex = outputFormats.firstIndex(of: .aac) {
            formatPopUp.selectItem(at: defaultIndex)
        }

        bitratePopUp.removeAllItems()
        for option in bitrateOptions {
            if option < 0 {
                bitratePopUp.addItem(withTitle: "Auto")
            } else {
                bitratePopUp.addItem(withTitle: "\(option) kbps")
            }
            bitratePopUp.lastItem?.tag = option
        }
        if let defaultBitrateIndex = bitrateOptions.firstIndex(of: 192) {
            bitratePopUp.selectItem(at: defaultBitrateIndex)
        }

        sampleRatePopUp.removeAllItems()
        for option in sampleRateOptions {
            if option < 0 {
                sampleRatePopUp.addItem(withTitle: "Source")
            } else {
                sampleRatePopUp.addItem(withTitle: "\(option) Hz")
            }
            sampleRatePopUp.lastItem?.tag = option
        }
        if let defaultRateIndex = sampleRateOptions.firstIndex(of: 44_100) {
            sampleRatePopUp.selectItem(at: defaultRateIndex)
        }

        folderStructurePopUp.removeAllItems()
        for mode in FolderStructureMode.allCases {
            folderStructurePopUp.addItem(withTitle: mode.title)
            folderStructurePopUp.lastItem?.representedObject = mode.rawValue
        }

        applyModePopUp.removeAllItems()
        for mode in TemplateApplyMode.allCases {
            applyModePopUp.addItem(withTitle: mode.title)
            applyModePopUp.lastItem?.representedObject = mode.rawValue
        }

        templatePresetPopUp.removeAllItems()
        for preset in TemplatePreset.allCases {
            templatePresetPopUp.addItem(withTitle: preset.title)
            templatePresetPopUp.lastItem?.representedObject = preset.rawValue
        }

        configureTokenOrderPopups()

        templateSeparatorPopUp.removeAllItems()
        for separator in templateSeparatorOptions {
            templateSeparatorPopUp.addItem(withTitle: separator.replacingOccurrences(of: " ", with: "·"))
            templateSeparatorPopUp.lastItem?.representedObject = separator
        }

        restoreFolderStructurePreferences()
        updateFormatDependentControls()
        updateTemplateOptionsVisibility()
        updateConvertButtonState()
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
        updateConvertButtonState()

        scanTask?.cancel()
        scanTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let tracks = await self.libraryScanService.scanFolder(folderURL)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.loadedTracks = tracks
                self.tableView.reloadData()

                if tracks.isEmpty {
                    self.statusField.stringValue = "No supported audio files found"
                    self.inspectorViewController.update(with: nil)
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.statusField.stringValue = "Loaded \(tracks.count) tracks"
                }
                self.updateConvertButtonState()
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

        let tracksToConvert: [LoadedTrack]
        if batchScopePopUp.indexOfSelectedItem == 1 {
            tracksToConvert = loadedTracks
        } else {
            tracksToConvert = tableView.selectedRowIndexes.compactMap { index in
                loadedTracks.indices.contains(index) ? loadedTracks[index] : nil
            }
        }

        guard !tracksToConvert.isEmpty else {
            showAlert(title: "No Tracks", message: "Select tracks or choose 'All Loaded Tracks' before converting.")
            return
        }

        let preset = buildPresetFromControls()

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false

        guard destinationPanel.runModal() == .OK, let destinationFolder = destinationPanel.url else {
            return
        }

        let folderMode = selectedFolderStructureMode()
        let templateConfig = selectedTemplateConfig()
        var reviewedAlbumFolders: [AlbumGroupKey: String] = [:]
        if folderMode == .metadataTemplate,
           selectedTemplateApplyMode() == .reviewPerAlbumPreflight {
            guard let reviewed = reviewAlbumFoldersPreflight(for: tracksToConvert, templateConfig: templateConfig) else {
                statusField.stringValue = "Conversion cancelled in preflight review."
                return
            }
            reviewedAlbumFolders = reviewed
        }

        var jobs: [ConversionJob] = []
        jobs.reserveCapacity(tracksToConvert.count)

        for loaded in tracksToConvert {
            let outputURL = destinationURL(
                for: loaded,
                preset: preset,
                destinationRoot: destinationFolder,
                folderMode: folderMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders
            )
            let job = ConversionJob(sourceURL: loaded.track.fileURL, destinationURL: outputURL, metadata: loaded.metadata)
            jobs.append(job)
        }

        conversionService.clearQueue()
        _ = conversionService.enqueue(jobs, preset: preset)

        statusField.stringValue = "Converting \(jobs.count) file(s) with \(preset.name)..."
        convertButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let results = conversionService.runQueuedJobs()

            DispatchQueue.main.async {
                let completed = results.filter { $0.status == .completed }.count
                let failed = results.filter { $0.status == .failed }.count
                let warnings = results.compactMap { $0.warning }

                self.statusField.stringValue = "Conversion complete. Success: \(completed), Failed: \(failed), Warnings: \(warnings.count)."
                self.updateConvertButtonState()

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

    @objc private func batchScopeChanged() {
        updateConvertButtonState()
    }

    @objc private func formatChanged() {
        updateFormatDependentControls()
    }

    @objc private func folderStructureChanged() {
        updateTemplateOptionsVisibility()
        saveFolderStructurePreferences()
    }

    @objc private func applyModeChanged() {
        saveFolderStructurePreferences()
    }

    @objc private func templatePresetChanged() {
        let preset = selectedTemplatePreset()
        if preset != .custom {
            applyTokenOrder(preset.defaultTokenOrder)
        }
        updateTemplateOptionsVisibility()
        saveFolderStructurePreferences()
    }

    @objc private func customTokenOrderChanged() {
        let normalized = normalizeTokenOrder(selectedCustomTokenOrder())
        applyTokenOrder(normalized)
        saveFolderStructurePreferences()
    }

    @objc private func templateSeparatorChanged() {
        saveFolderStructurePreferences()
    }

    private func configureTokenOrderPopups() {
        let popups = [tokenOrderPopUp1, tokenOrderPopUp2, tokenOrderPopUp3]
        for popup in popups {
            popup.removeAllItems()
            for token in FolderToken.allCases {
                popup.addItem(withTitle: token.title)
                popup.lastItem?.representedObject = token.rawValue
            }
        }
    }

    private func restoreFolderStructurePreferences() {
        let mode = FolderStructureMode(rawValue: defaults.string(forKey: defaultsFolderStructureModeKey) ?? "") ?? .sourceRelative
        select(folderStructurePopUp, rawValue: mode.rawValue)

        let applyMode = TemplateApplyMode(rawValue: defaults.string(forKey: defaultsTemplateApplyModeKey) ?? "") ?? .applyAll
        select(applyModePopUp, rawValue: applyMode.rawValue)

        let preset = TemplatePreset(rawValue: defaults.string(forKey: defaultsTemplatePresetKey) ?? "") ?? .artistYearAlbum
        select(templatePresetPopUp, rawValue: preset.rawValue)

        let separator = defaults.string(forKey: defaultsTemplateSeparatorKey) ?? " - "
        select(templateSeparatorPopUp, rawValue: separator)

        let storedOrder = defaults.stringArray(forKey: defaultsTokenOrderKey) ?? preset.defaultTokenOrder.map(\.rawValue)
        let parsed = storedOrder.compactMap(FolderToken.init(rawValue:))
        let normalizedOrder = normalizeTokenOrder(parsed.isEmpty ? preset.defaultTokenOrder : parsed)
        applyTokenOrder(normalizedOrder)

        updateTemplateOptionsVisibility()
    }

    private func saveFolderStructurePreferences() {
        defaults.set(selectedFolderStructureMode().rawValue, forKey: defaultsFolderStructureModeKey)
        defaults.set(selectedTemplatePreset().rawValue, forKey: defaultsTemplatePresetKey)
        defaults.set(selectedTemplateApplyMode().rawValue, forKey: defaultsTemplateApplyModeKey)
        defaults.set(selectedCustomTokenOrder().map(\.rawValue), forKey: defaultsTokenOrderKey)
        defaults.set(selectedTemplateSeparator(), forKey: defaultsTemplateSeparatorKey)
    }

    private func updateTemplateOptionsVisibility() {
        let metadataModeSelected = selectedFolderStructureMode() == .metadataTemplate
        templateOptionsStack.isHidden = !metadataModeSelected
        applyModePopUp.isEnabled = metadataModeSelected

        let customSelected = selectedTemplatePreset() == .custom
        customOrderStack.isHidden = !metadataModeSelected || !customSelected
    }

    private func select(_ popUp: NSPopUpButton, rawValue: String) {
        for item in popUp.itemArray where (item.representedObject as? String) == rawValue {
            popUp.select(item)
            return
        }
    }

    private func applyTokenOrder(_ order: [FolderToken]) {
        let normalized = normalizeTokenOrder(order)
        let popups = [tokenOrderPopUp1, tokenOrderPopUp2, tokenOrderPopUp3]
        for (index, token) in normalized.enumerated() where index < popups.count {
            select(popups[index], rawValue: token.rawValue)
        }
    }

    private func selectedCustomTokenOrder() -> [FolderToken] {
        let rawValues = [tokenOrderPopUp1, tokenOrderPopUp2, tokenOrderPopUp3].compactMap {
            $0.selectedItem?.representedObject as? String
        }
        return rawValues.compactMap(FolderToken.init(rawValue:))
    }

    private func normalizeTokenOrder(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []
        let fallbackQueue = FolderToken.allCases

        for token in order {
            if !used.contains(token) {
                normalized.append(token)
                used.insert(token)
            } else if let fallback = fallbackQueue.first(where: { !used.contains($0) }) {
                normalized.append(fallback)
                used.insert(fallback)
            }
        }

        while normalized.count < FolderToken.allCases.count {
            if let fallback = fallbackQueue.first(where: { !used.contains($0) }) {
                normalized.append(fallback)
                used.insert(fallback)
            } else {
                break
            }
        }

        return normalized
    }

    private func updateFormatDependentControls() {
        let format = selectedOutputFormat()
        let lossless = isLosslessFormat(format)

        bitratePopUp.isEnabled = !lossless
        if lossless {
            bitratePopUp.selectItem(withTag: -1)
        }
    }

    private func updateConvertButtonState() {
        guard !loadedTracks.isEmpty else {
            convertButton.isEnabled = false
            convertButton.title = "Convert"
            return
        }

        if batchScopePopUp.indexOfSelectedItem == 1 {
            convertButton.isEnabled = true
            convertButton.title = "Convert All"
        } else {
            convertButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
            convertButton.title = "Convert Selected"
        }
    }

    private func buildPresetFromControls() -> ConversionPreset {
        let format = selectedOutputFormat()
        let userBitrate = selectedBitrate()
        let userSampleRate = selectedSampleRate()

        let bitrate: Int?
        if isLosslessFormat(format) {
            bitrate = nil
        } else if let userBitrate {
            bitrate = userBitrate
        } else {
            bitrate = defaultBitrate(for: format)
        }

        let deviceProfile: DeviceProfile = (format == .mp3 || format == .aac) ? .ipodLegacySafe : .generic
        let tagMode: TagMode
        switch format {
        case .mp3:
            tagMode = .id3v23
        case .aac, .alac:
            tagMode = .mp4Atoms
        default:
            tagMode = .auto
        }

        let sampleRate: Int?
        if let userSampleRate {
            sampleRate = userSampleRate
        } else if deviceProfile == .ipodLegacySafe {
            sampleRate = 44_100
        } else {
            sampleRate = nil
        }

        let channels: Int? = deviceProfile == .ipodLegacySafe ? 2 : nil
        let constantBitrate = format == .mp3 && bitrate != nil
        let bitrateName = bitrate.map { "\($0) kbps" } ?? "Auto"
        let sampleRateName = sampleRate.map { "\($0) Hz" } ?? "Source"

        return ConversionPreset(
            id: "custom_\(format.rawValue)_\(bitrate ?? 0)_\(sampleRate ?? 0)_\(deviceProfile.rawValue)",
            name: "\(displayName(for: format)) • \(bitrateName) • \(sampleRateName)",
            outputFormat: format,
            bitrateKbps: bitrate,
            sampleRateHz: sampleRate,
            channels: channels,
            constantBitrate: constantBitrate,
            deviceProfile: deviceProfile,
            tagMode: tagMode,
            artworkMode: .compatReembed
        )
    }

    private func selectedOutputFormat() -> OutputFormat {
        if let rawValue = formatPopUp.selectedItem?.representedObject as? String,
           let format = OutputFormat(rawValue: rawValue) {
            return format
        }
        return .aac
    }

    private func selectedBitrate() -> Int? {
        let tag = bitratePopUp.selectedTag()
        return tag > 0 ? tag : nil
    }

    private func selectedSampleRate() -> Int? {
        let tag = sampleRatePopUp.selectedTag()
        return tag > 0 ? tag : nil
    }

    private func defaultBitrate(for format: OutputFormat) -> Int? {
        switch format {
        case .mp3, .aac, .ogg:
            return 192
        case .opus:
            return 160
        case .alac, .flac, .wav, .aiff:
            return nil
        }
    }

    private func isLosslessFormat(_ format: OutputFormat) -> Bool {
        switch format {
        case .alac, .flac, .wav, .aiff:
            return true
        case .mp3, .aac, .ogg, .opus:
            return false
        }
    }

    private func displayName(for format: OutputFormat) -> String {
        switch format {
        case .mp3:
            return "MP3"
        case .aac:
            return "AAC (M4A)"
        case .alac:
            return "ALAC (M4A)"
        case .flac:
            return "FLAC"
        case .wav:
            return "WAV"
        case .aiff:
            return "AIFF"
        case .ogg:
            return "Ogg Vorbis"
        case .opus:
            return "Opus"
        }
    }

    private func selectedFolderStructureMode() -> FolderStructureMode {
        if let raw = folderStructurePopUp.selectedItem?.representedObject as? String,
           let mode = FolderStructureMode(rawValue: raw) {
            return mode
        }
        return .sourceRelative
    }

    private func selectedTemplatePreset() -> TemplatePreset {
        if let raw = templatePresetPopUp.selectedItem?.representedObject as? String,
           let preset = TemplatePreset(rawValue: raw) {
            return preset
        }
        return .artistYearAlbum
    }

    private func selectedTemplateApplyMode() -> TemplateApplyMode {
        if let raw = applyModePopUp.selectedItem?.representedObject as? String,
           let mode = TemplateApplyMode(rawValue: raw) {
            return mode
        }
        return .applyAll
    }

    private func selectedTemplateSeparator() -> String {
        (templateSeparatorPopUp.selectedItem?.representedObject as? String) ?? " - "
    }

    private func selectedTemplateConfig() -> TemplateConfig {
        let preset = selectedTemplatePreset()
        let tokenOrder = preset == .custom ? normalizeTokenOrder(selectedCustomTokenOrder()) : preset.defaultTokenOrder
        return TemplateConfig(
            preset: preset,
            tokenOrder: tokenOrder,
            separator: selectedTemplateSeparator()
        )
    }

    private func albumGroupKey(for loadedTrack: LoadedTrack) -> AlbumGroupKey {
        let artist = sanitizePathComponent(loadedTrack.metadata.artist ?? loadedTrack.track.artist, fallback: unknownArtist)
        let album = sanitizePathComponent(loadedTrack.metadata.album ?? loadedTrack.track.album, fallback: unknownAlbum)
        let yearValue = loadedTrack.metadata.year.map(String.init) ?? ""
        let year = sanitizePathComponent(yearValue, fallback: unknownYear)
        return AlbumGroupKey(artist: artist, album: album, year: year)
    }

    private func reviewAlbumFoldersPreflight(
        for tracks: [LoadedTrack],
        templateConfig: TemplateConfig
    ) -> [AlbumGroupKey: String]? {
        var grouped: [AlbumGroupKey: LoadedTrack] = [:]
        for track in tracks {
            let key = albumGroupKey(for: track)
            if grouped[key] == nil {
                grouped[key] = track
            }
        }

        let sortedKeys = grouped.keys.sorted {
            if $0.artist != $1.artist { return $0.artist < $1.artist }
            if $0.album != $1.album { return $0.album < $1.album }
            return $0.year < $1.year
        }

        var reviewed: [AlbumGroupKey: String] = [:]
        for (index, key) in sortedKeys.enumerated() {
            guard let representative = grouped[key] else { continue }
            let proposed = buildOutputSubpath(loadedTrack: representative, templateConfig: templateConfig)

            let alert = NSAlert()
            alert.messageText = "Album Folder \(index + 1) of \(sortedKeys.count)"
            alert.informativeText = "\(key.artist) • \(key.album) • \(key.year)\nEdit destination subfolder:"
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            inputField.stringValue = proposed
            alert.accessoryView = inputField

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                return nil
            }

            let customValue = sanitizeRelativeSubpath(inputField.stringValue, fallback: proposed)
            reviewed[key] = customValue
        }

        return reviewed
    }

    private func buildOutputSubpath(
        loadedTrack: LoadedTrack,
        templateConfig: TemplateConfig
    ) -> String {
        let values: [FolderToken: String] = [
            .year: sanitizePathComponent(loadedTrack.metadata.year.map(String.init) ?? "", fallback: unknownYear),
            .artist: sanitizePathComponent(loadedTrack.metadata.artist ?? loadedTrack.track.artist, fallback: unknownArtist),
            .album: sanitizePathComponent(loadedTrack.metadata.album ?? loadedTrack.track.album, fallback: unknownAlbum)
        ]

        switch templateConfig.preset {
        case .artistYearAlbum:
            return sanitizeRelativeSubpath(
                "\(values[.artist] ?? unknownArtist)/\(values[.year] ?? unknownYear)\(templateConfig.separator)\(values[.album] ?? unknownAlbum)",
                fallback: "\(unknownArtist)/\(unknownYear)\(templateConfig.separator)\(unknownAlbum)"
            )
        case .yearArtistAlbum:
            return sanitizeRelativeSubpath(
                "\(values[.year] ?? unknownYear)/\(values[.artist] ?? unknownArtist)/\(values[.album] ?? unknownAlbum)",
                fallback: "\(unknownYear)/\(unknownArtist)/\(unknownAlbum)"
            )
        case .artistAlbumYear:
            return sanitizeRelativeSubpath(
                "\(values[.artist] ?? unknownArtist)/\(values[.album] ?? unknownAlbum) (\(values[.year] ?? unknownYear))",
                fallback: "\(unknownArtist)/\(unknownAlbum) (\(unknownYear))"
            )
        case .custom:
            let components = templateConfig.tokenOrder.map { token in
                values[token] ?? fallbackValue(for: token)
            }
            let rawPath = components.joined(separator: "/")
            return sanitizeRelativeSubpath(rawPath, fallback: "\(unknownArtist)/\(unknownAlbum)/\(unknownYear)")
        }
    }

    private func fallbackValue(for token: FolderToken) -> String {
        switch token {
        case .year:
            return unknownYear
        case .artist:
            return unknownArtist
        case .album:
            return unknownAlbum
        }
    }

    private func sanitizePathComponent(_ rawValue: String, fallback: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return fallback }

        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\\", with: "-")

        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func sanitizeRelativeSubpath(_ rawPath: String, fallback: String) -> String {
        let components = rawPath
            .split(separator: "/")
            .map { sanitizePathComponent(String($0), fallback: "") }
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return fallback
        }
        return components.joined(separator: "/")
    }

    private func destinationURL(
        for loadedTrack: LoadedTrack,
        preset: ConversionPreset,
        destinationRoot: URL,
        folderMode: FolderStructureMode,
        templateConfig: TemplateConfig,
        reviewedAlbumFolders: [AlbumGroupKey: String]
    ) -> URL {
        let track = loadedTrack.track
        let sourceDirectory = track.fileURL.deletingLastPathComponent()
        var outputDirectory = destinationRoot

        switch folderMode {
        case .sourceRelative:
            if let root = currentLibraryRoot {
                let rootComponents = root.standardizedFileURL.pathComponents
                let sourceComponents = sourceDirectory.standardizedFileURL.pathComponents

                if sourceComponents.starts(with: rootComponents) {
                    for component in sourceComponents.dropFirst(rootComponents.count) {
                        outputDirectory.appendPathComponent(component, isDirectory: true)
                    }
                }
            }
        case .flat:
            break
        case .metadataTemplate:
            let key = albumGroupKey(for: loadedTrack)
            let subpath = reviewedAlbumFolders[key] ?? buildOutputSubpath(loadedTrack: loadedTrack, templateConfig: templateConfig)
            for component in subpath.split(separator: "/").map(String.init) where !component.isEmpty {
                outputDirectory.appendPathComponent(component, isDirectory: true)
            }
        }

        let baseName = sanitizePathComponent(track.fileURL.deletingPathExtension().lastPathComponent, fallback: "Track")
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

private final class ClassicRowView: NSTableRowView {
    var rowIndex: Int = 0

    override func drawBackground(in dirtyRect: NSRect) {
        if rowIndex % 2 == 0 {
            NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
            dirtyRect.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = dirtyRect.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)

        if let gradient = NSGradient(colors: [
            ClassicTheme.accentHighlight,
            ClassicTheme.accentYellow,
            ClassicTheme.accentShadow
        ]) {
            gradient.draw(in: path, angle: -90)
        } else {
            ClassicTheme.accentYellow.setFill()
            path.fill()
        }

        ClassicTheme.chromeStroke.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
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
