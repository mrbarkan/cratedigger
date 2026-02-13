import AppKit
import CrateDiggerCore

enum FolderStructureMode: String, CaseIterable {
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

enum FolderToken: String, CaseIterable {
    case disabled
    case year
    case albumArtist = "album_artist"
    case album
    case compilation

    var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .year:
            return "Year"
        case .albumArtist:
            return "Album Artist"
        case .album:
            return "Album"
        case .compilation:
            return "Compilation"
        }
    }

    var isDisabled: Bool {
        self == .disabled
    }
}

enum TemplateApplyMode: String, CaseIterable {
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

enum TemplatePreset: String, CaseIterable {
    case artistYearAlbum
    case yearArtistAlbum
    case artistAlbumYear
    case custom

    var title: String {
        switch self {
        case .artistYearAlbum:
            return "Album Artist / Year / Album"
        case .yearArtistAlbum:
            return "Year / Album Artist / Album"
        case .artistAlbumYear:
            return "Album Artist / Album / Year"
        case .custom:
            return "Custom Order"
        }
    }

    var defaultTokenOrder: [FolderToken] {
        switch self {
        case .artistYearAlbum:
            return [.albumArtist, .year, .album]
        case .yearArtistAlbum:
            return [.year, .albumArtist, .album]
        case .artistAlbumYear:
            return [.albumArtist, .album, .year]
        case .custom:
            return [.year, .albumArtist, .album, .compilation, .disabled]
        }
    }
}

private struct AlbumGroupKey: Hashable {
    let artistBucket: String
    let album: String
    let year: String
}

private struct TemplateConfig {
    let preset: TemplatePreset
    let tokenOrder: [FolderToken]
}

private struct MultiRootScanResult {
    let tracks: [LoadedTrack]
    let sourceRootByTrackPath: [String: URL]
}

private enum ToolbarActivityState {
    case idle
    case running
    case paused
    case disabled
}

private enum ToolbarCompletionState {
    case idle
    case info
    case success
    case warning
    case error
}

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let artworkService = ArtworkService()
    private lazy var libraryScanService = LibraryScanService(artworkService: artworkService)

    private var conversionService: ConversionService?
    private var conversionServiceInitializationError: Error?
    private var scanTask: Task<Void, Never>?

    private var loadedTracks: [LoadedTrack] = []
    private var sourceRootByTrackPath: [String: URL] = [:]

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
    private let tokenOrderPopUp4 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenOrderPopUp5 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let templateOptionsStack = NSStackView()
    private let customOrderStack = NSStackView()
    private let statusField = NSTextField(labelWithString: "Load a folder to begin")
    private let convertButton = NSButton(title: "CONVERT", target: nil, action: nil)
    private let lcdView = AquaLCDView()
    private let topBar = NSVisualEffectView()
    private let bottomBar = NSVisualEffectView()
    private let activityIndicatorView = NSView()
    private let completionIndicatorView = NSView()
    private var conversionOptionsSheetWindow: NSWindow?
    private var lcdSecondaryStatusOverride: String?
    private var lcdSecondaryToneOverride: ModernRetroTheme.StatusTone = .neutral
    private var lcdBarProgressOverride: Double = 0
    private var lcdSecondaryResetWorkItem: DispatchWorkItem?
    private var isConversionRunning = false
    private var toolbarActivityState: ToolbarActivityState = .idle
    private var toolbarCompletionState: ToolbarCompletionState = .idle

    private let inspectorViewController = TrackInspectorViewController()
    private let outputFormats: [OutputFormat] = [.mp3, .aac, .alac, .flac, .wav, .aiff, .ogg, .opus]
    private let bitrateOptions = [-1, 96, 128, 160, 192, 256, 320]
    private let sampleRateOptions = [-1, 32000, 44100, 48000, 96000]
    private let unknownArtist = "Unknown Artist"
    private let unknownAlbum = "Unknown Album"
    private let unknownYear = "Unknown Year"

    private let defaults = UserDefaults.standard
    private let defaultsFolderStructureModeKey = "CrateDigger.folderStructureMode"
    private let defaultsTemplatePresetKey = "CrateDigger.templatePreset"
    private let defaultsTemplateApplyModeKey = "CrateDigger.templateApplyMode"
    private let defaultsTokenOrderKey = "CrateDigger.templateTokenOrder"
    private let defaultsLastLoadFolderPathKey = "CrateDigger.lastLoadFolderPath"
    private let defaultsLastConvertFolderPathKey = "CrateDigger.lastConvertFolderPath"

    deinit {
        scanTask?.cancel()
        lcdSecondaryResetWorkItem?.cancel()
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ModernRetroTheme.surfaceBase.cgColor

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

        configureTopBar()
        configureBottomBar()

        view.addSubview(topBar)
        view.addSubview(splitView)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ModernRetroTheme.toolbarHeight),

            splitView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            leftContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 28)
        ])

        configureConversionOptions()
        configureServices()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        ModernRetroTheme.updateButtonLayers(openFolderButton)
        ModernRetroTheme.updateButtonLayers(convertButton)
        updateToolbarIndicators(activity: toolbarActivityState, completion: toolbarCompletionState)
        lcdView.layoutSubtreeIfNeeded()
        updateLCD()
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = preferredLoadDirectoryURL()

        guard panel.runModal() == .OK else {
            return
        }

        let selectedFolders = panel.urls
        guard !selectedFolders.isEmpty else {
            return
        }

        if let firstFolder = selectedFolders.first {
            saveLastLoadDirectory(firstFolder)
        }
        loadTracks(from: selectedFolders)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        loadedTracks.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        50
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ModernRowView()
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
            updateLCD()
            return
        }

        inspectorViewController.update(with: loadedTracks[tableView.selectedRow])
        updateConvertButtonState()
        updateLCD()
    }

    private func configureLeftPane(in container: NSView) {
        let templatePresetLabel = NSTextField(labelWithString: "Folder Order:")
        let tokenOrderLabel = NSTextField(labelWithString: "Token Order:")

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
        tokenOrderPopUp4.target = self
        tokenOrderPopUp4.action = #selector(customTokenOrderChanged)
        tokenOrderPopUp5.target = self
        tokenOrderPopUp5.action = #selector(customTokenOrderChanged)

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
            tokenOrderPopUp4,
            tokenOrderPopUp5
        ].forEach(stylePopUp)

        customOrderStack.orientation = .horizontal
        customOrderStack.alignment = .centerY
        customOrderStack.spacing = 10
        customOrderStack.addArrangedSubview(tokenOrderLabel)
        customOrderStack.addArrangedSubview(tokenOrderPopUp1)
        customOrderStack.addArrangedSubview(tokenOrderPopUp2)
        customOrderStack.addArrangedSubview(tokenOrderPopUp3)
        customOrderStack.addArrangedSubview(tokenOrderPopUp4)
        customOrderStack.addArrangedSubview(tokenOrderPopUp5)

        templateOptionsStack.orientation = .vertical
        templateOptionsStack.alignment = .leading
        templateOptionsStack.spacing = 6
        let templatePresetControls = NSStackView(views: [templatePresetLabel, templatePresetPopUp])
        templatePresetControls.orientation = .horizontal
        templatePresetControls.alignment = .centerY
        templatePresetControls.spacing = 10
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
        tableView.focusRingType = .none
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.scrollerStyle = .legacy
        ModernRetroTheme.styleListContainer(scrollView: scrollView, tableView: tableView)

        let contentStack = NSStackView(views: [scrollView])
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: ModernRetroTheme.contentInsets.top),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ModernRetroTheme.contentInsets.left),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ModernRetroTheme.contentInsets.right),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -ModernRetroTheme.contentInsets.bottom),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    private func stylePopUp(_ popUp: NSPopUpButton) {
        ModernRetroTheme.stylePopUp(popUp)
    }

    private func configureTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        ModernRetroTheme.applyChromeMaterial(to: topBar)

        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderAction)
        ModernRetroTheme.stylePrimaryActionButton(openFolderButton, title: "LOAD", minWidth: ModernRetroTheme.toolbarPrimaryButtonWidth)

        convertButton.target = self
        convertButton.action = #selector(convertSelectedTracks)
        convertButton.isEnabled = false
        ModernRetroTheme.stylePrimaryActionButton(convertButton, title: "CONVERT", minWidth: ModernRetroTheme.toolbarPrimaryButtonWidth)

        let leftStack = NSStackView(views: [openFolderButton, convertButton])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = ModernRetroTheme.toolbarClusterSpacing
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        configureIndicator(activityIndicatorView)
        configureIndicator(completionIndicatorView)
        let indicatorStack = NSStackView(views: [activityIndicatorView, completionIndicatorView])
        indicatorStack.orientation = .horizontal
        indicatorStack.alignment = .centerY
        indicatorStack.spacing = 8
        indicatorStack.translatesAutoresizingMaskIntoConstraints = false

        lcdView.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(leftStack)
        topBar.addSubview(lcdView)
        topBar.addSubview(indicatorStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: ModernRetroTheme.toolbarClusterLeadingInset),
            leftStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            lcdView.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            lcdView.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            lcdView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            lcdView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            lcdView.heightAnchor.constraint(equalToConstant: 56),

            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: lcdView.leadingAnchor, constant: -42),
            indicatorStack.leadingAnchor.constraint(greaterThanOrEqualTo: lcdView.trailingAnchor, constant: 26),
            indicatorStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            indicatorStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -(ModernRetroTheme.contentInsets.right + 4))
        ])

        updateToolbarIndicators(activity: .idle, completion: .idle)
    }

    private func configureBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        ModernRetroTheme.applyChromeMaterial(to: bottomBar)

        statusField.textColor = ModernRetroTheme.textSecondary
        statusField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusField.translatesAutoresizingMaskIntoConstraints = false

        bottomBar.addSubview(statusField)

        let topLine = NSView()
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = ModernRetroTheme.separator.withAlphaComponent(0.45).cgColor
        bottomBar.addSubview(topLine)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            statusField.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: ModernRetroTheme.contentInsets.left),
            statusField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
    }

    private func configureIndicator(_ indicatorView: NSView) {
        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 4.5
        indicatorView.layer?.borderWidth = 1
        indicatorView.layer?.borderColor = ModernRetroTheme.separator.withAlphaComponent(0.45).cgColor
        indicatorView.layer?.backgroundColor = ModernRetroTheme.indicatorIdle.withAlphaComponent(0.45).cgColor
        NSLayoutConstraint.activate([
            indicatorView.widthAnchor.constraint(equalToConstant: 9),
            indicatorView.heightAnchor.constraint(equalToConstant: 9)
        ])
    }

    private func updateToolbarIndicators(activity: ToolbarActivityState, completion: ToolbarCompletionState) {
        toolbarActivityState = activity
        toolbarCompletionState = completion

        let activityColor: NSColor
        switch activity {
        case .idle:
            activityColor = ModernRetroTheme.indicatorIdle
        case .running:
            activityColor = ModernRetroTheme.indicatorInfo
        case .paused:
            activityColor = ModernRetroTheme.indicatorWarning
        case .disabled:
            activityColor = ModernRetroTheme.indicatorIdle.withAlphaComponent(0.55)
        }

        let completionColor: NSColor
        switch completion {
        case .idle:
            completionColor = ModernRetroTheme.indicatorIdle
        case .info:
            completionColor = ModernRetroTheme.indicatorInfo
        case .success:
            completionColor = ModernRetroTheme.indicatorSuccess
        case .warning:
            completionColor = ModernRetroTheme.indicatorWarning
        case .error:
            completionColor = ModernRetroTheme.indicatorError
        }

        applyIndicatorAppearance(activityIndicatorView, color: activityColor, dimmed: activity == .disabled)
        applyIndicatorAppearance(completionIndicatorView, color: completionColor, dimmed: false)
        setActivityPulse(enabled: activity == .running)
    }

    private func applyIndicatorAppearance(_ indicatorView: NSView, color: NSColor, dimmed: Bool) {
        indicatorView.layer?.backgroundColor = color.withAlphaComponent(dimmed ? 0.18 : 0.85).cgColor
        indicatorView.layer?.borderColor = color.withAlphaComponent(dimmed ? 0.25 : 0.62).cgColor
    }

    private func setActivityPulse(enabled: Bool) {
        let animationKey = "ModernRetro.ActivityPulse"
        if enabled {
            guard activityIndicatorView.layer?.animation(forKey: animationKey) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.35
            pulse.toValue = 1.0
            pulse.duration = ModernRetroTheme.activityPulseDuration
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            activityIndicatorView.layer?.add(pulse, forKey: animationKey)
        } else {
            activityIndicatorView.layer?.removeAnimation(forKey: animationKey)
            activityIndicatorView.layer?.opacity = 1.0
        }
    }

    private func toolbarCompletionState(for tone: ModernRetroTheme.StatusTone) -> ToolbarCompletionState {
        switch tone {
        case .neutral:
            return .idle
        case .info:
            return .info
        case .success:
            return .success
        case .warning:
            return .warning
        case .error:
            return .error
        }
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

        restoreFolderStructurePreferences()
        updateFormatDependentControls()
        updateTemplateOptionsVisibility()
        updateConvertButtonState()
    }

    private func configureServices() {
        do {
            conversionService = try ConversionService(artworkPreparer: artworkService)
            updateToolbarIndicators(activity: .idle, completion: .idle)
        } catch {
            conversionServiceInitializationError = error
            setStatus("ffmpeg was not found. Loading and artwork preview work; conversion is unavailable.")
            updateToolbarIndicators(activity: .disabled, completion: .error)
        }
    }

    private func loadTracks(from folderURLs: [URL]) {
        let uniqueRoots = deduplicatedRoots(from: folderURLs)
        guard !uniqueRoots.isEmpty else {
            return
        }

        let folderSummary = uniqueRoots.count == 1
            ? uniqueRoots[0].lastPathComponent
            : "\(uniqueRoots.count) folders"
        setStatus("Scanning \(folderSummary)...")
        updateConvertButtonState()

        scanTask?.cancel()
        scanTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let result = await self.scanFolders(uniqueRoots)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.loadedTracks = result.tracks
                self.sourceRootByTrackPath = result.sourceRootByTrackPath
                self.tableView.reloadData()

                if result.tracks.isEmpty {
                    self.setStatus("No supported audio files found")
                    self.inspectorViewController.update(with: nil)
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.setStatus("Loaded \(result.tracks.count) tracks")
                }
                self.updateConvertButtonState()
                self.updateLCD()
            }
        }
    }

    private func scanFolders(_ roots: [URL]) async -> MultiRootScanResult {
        let scannedGroups = await withTaskGroup(of: (Int, URL, [LoadedTrack]).self) { group in
            for (index, root) in roots.enumerated() {
                group.addTask { [libraryScanService] in
                    let tracks = await libraryScanService.scanFolder(root)
                    return (index, root, tracks)
                }
            }

            var collected: [(Int, URL, [LoadedTrack])] = []
            for await scanned in group {
                collected.append(scanned)
            }
            return collected
        }

        let ordered = scannedGroups.sorted { $0.0 < $1.0 }
        var mergedTracks: [LoadedTrack] = []
        var seenPaths: Set<String> = []
        var rootByTrackPath: [String: URL] = [:]

        for (_, root, tracks) in ordered {
            for loaded in tracks {
                let key = trackPathKey(for: loaded.track.fileURL)
                guard seenPaths.insert(key).inserted else {
                    continue
                }
                mergedTracks.append(loaded)
                rootByTrackPath[key] = root
            }
        }

        let sortedTracks = mergedTracks.sorted { lhs, rhs in
            let lhsTitle = lhs.track.title
            let rhsTitle = rhs.track.title
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }
            return lhs.track.fileURL.path.localizedCaseInsensitiveCompare(rhs.track.fileURL.path) == .orderedAscending
        }

        return MultiRootScanResult(
            tracks: sortedTracks,
            sourceRootByTrackPath: rootByTrackPath
        )
    }

    private func deduplicatedRoots(from roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []

        for root in roots {
            let key = trackPathKey(for: root)
            guard seen.insert(key).inserted else {
                continue
            }
            unique.append(root)
        }

        return unique
    }

    private func trackPathKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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

        guard !loadedTracks.isEmpty else {
            showAlert(title: "No Tracks", message: "Load tracks before converting.")
            return
        }

        presentConversionOptionsSheet { [weak self] selection in
            guard let self else { return }

            guard let selection else {
                self.setStatus("Conversion cancelled.")
                self.updateToolbarIndicators(activity: .idle, completion: .warning)
                self.setLCDConversionStatus("Conversion cancelled", tone: .warning, progress: 0)
                self.scheduleClearLCDConversionStatus(after: 1.8, resetCompletionIndicator: true)
                return
            }

            self.applyConversionOptionsSelection(selection)
            self.runConversion(with: selection, conversionService: conversionService)
        }
    }

    private func runConversion(with selection: ConversionOptionsSelection, conversionService: ConversionService) {
        let tracksToConvert = tracksToConvert(for: selection.batchScope)
        guard !tracksToConvert.isEmpty else {
            showAlert(title: "No Tracks", message: "Select tracks or choose 'All Loaded Tracks' in options before converting.")
            return
        }

        let preset = buildPresetFromControls()

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.directoryURL = preferredConvertDirectoryURL()

        guard destinationPanel.runModal() == .OK, let destinationFolder = destinationPanel.url else {
            setStatus("Conversion cancelled.")
            updateToolbarIndicators(activity: .idle, completion: .warning)
            setLCDConversionStatus("Conversion cancelled", tone: .warning, progress: 0)
            scheduleClearLCDConversionStatus(after: 1.8, resetCompletionIndicator: true)
            return
        }
        saveLastConvertDirectory(destinationFolder)

        let folderMode = selectedFolderStructureMode()
        let templateConfig = selectedTemplateConfig()
        var reviewedAlbumFolders: [AlbumGroupKey: String] = [:]
        if folderMode == .metadataTemplate,
           selectedTemplateApplyMode() == .reviewPerAlbumPreflight {
            guard let reviewed = reviewAlbumFoldersPreflight(for: tracksToConvert, templateConfig: templateConfig) else {
                setStatus("Conversion cancelled in preflight review.")
                updateToolbarIndicators(activity: .idle, completion: .warning)
                setLCDConversionStatus("Conversion cancelled in preflight", tone: .warning, progress: 0)
                scheduleClearLCDConversionStatus(after: 2.2, resetCompletionIndicator: true)
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

        isConversionRunning = true
        setStatus("Converting \(jobs.count) file(s) with \(preset.name)...")
        updateToolbarIndicators(activity: .running, completion: .info)
        setLCDConversionStatus("Converting 0/\(jobs.count) • Failed: 0 • Warnings: 0", tone: .info, progress: 0)
        convertButton.isEnabled = false
        ModernRetroTheme.updateButtonLayers(convertButton)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let progressLock = NSLock()
            var currentFailed = 0
            var currentWarnings = 0

            let results = conversionService.runQueuedJobs(onJobFinished: { result, processed, total in
                progressLock.lock()
                if result.status == .failed {
                    currentFailed += 1
                }
                if result.warning != nil {
                    currentWarnings += 1
                }
                let failedSnapshot = currentFailed
                let warningsSnapshot = currentWarnings
                progressLock.unlock()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let progress = total > 0 ? Double(processed) / Double(total) : 0
                    self.setLCDConversionStatus(
                        "Converting \(processed)/\(total) • Failed: \(failedSnapshot) • Warnings: \(warningsSnapshot)",
                        tone: .info,
                        progress: progress
                    )
                }
            })

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let completed = results.filter { $0.status == .completed }.count
                let failed = results.filter { $0.status == .failed }.count
                let warningSummary = summarizeWarnings(from: results)
                let warningCount = warningSummary.totalCount

                self.isConversionRunning = false
                self.setStatus("Conversion complete. Success: \(completed), Failed: \(failed), Warnings: \(warningCount).")
                let completionTone: ModernRetroTheme.StatusTone
                if failed > 0 {
                    completionTone = .error
                } else if warningCount > 0 {
                    completionTone = .warning
                } else {
                    completionTone = .success
                }
                self.updateToolbarIndicators(activity: .idle, completion: self.toolbarCompletionState(for: completionTone))
                self.setLCDConversionStatus(
                    "Finished • Success: \(completed) • Failed: \(failed) • Warnings: \(warningCount)",
                    tone: completionTone,
                    progress: 1.0
                )
                self.scheduleClearLCDConversionStatus(after: 3.8)
                self.updateConvertButtonState()

                var message = "Completed: \(completed)\nFailed: \(failed)"
                if !warningSummary.items.isEmpty {
                    let preview = warningSummary.items.prefix(5).map { item in
                        if item.count > 1 {
                            return "\(item.message) (\(item.count)x)"
                        }
                        return item.message
                    }
                    message += "\nWarnings:\n- " + preview.joined(separator: "\n- ")
                    if warningSummary.items.count > 5 {
                        message += "\n- \(warningSummary.items.count - 5) more warning type(s)"
                    }
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

    private func tracksToConvert(for batchScope: ConversionBatchScope) -> [LoadedTrack] {
        if batchScope == .allLoadedTracks {
            return loadedTracks
        }

        return tableView.selectedRowIndexes.compactMap { index in
            loadedTracks.indices.contains(index) ? loadedTracks[index] : nil
        }
    }

    private func presentConversionOptionsSheet(completion: @escaping (ConversionOptionsSelection?) -> Void) {
        guard let hostWindow = view.window else {
            completion(nil)
            return
        }

        let controller = ConversionOptionsSheetController(
            initialSelection: currentConversionOptionsSelection(),
            outputFormats: outputFormats,
            bitrateOptions: bitrateOptions,
            sampleRateOptions: sampleRateOptions
        )

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Conversion Options"
        sheetWindow.backgroundColor = ModernRetroTheme.surfaceBase
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.contentViewController = controller
        sheetWindow.standardWindowButton(.closeButton)?.isHidden = true
        conversionOptionsSheetWindow = sheetWindow

        controller.onDecision = { [weak self, weak hostWindow, weak sheetWindow] selection in
            guard let self, let hostWindow, let sheetWindow else { return }
            hostWindow.endSheet(sheetWindow)
            self.conversionOptionsSheetWindow = nil
            completion(selection)
        }

        hostWindow.beginSheet(sheetWindow, completionHandler: nil)
    }

    private func currentConversionOptionsSelection() -> ConversionOptionsSelection {
        ConversionOptionsSelection(
            batchScope: batchScopePopUp.indexOfSelectedItem == 1 ? .allLoadedTracks : .selectedTracks,
            outputFormat: selectedOutputFormat(),
            bitrate: selectedBitrate(),
            sampleRate: selectedSampleRate(),
            folderStructureMode: selectedFolderStructureMode(),
            applyMode: selectedTemplateApplyMode(),
            templatePreset: selectedTemplatePreset(),
            tokenOrder: normalizeCustomTokenOrder(selectedCustomTokenOrder())
        )
    }

    private func applyConversionOptionsSelection(_ selection: ConversionOptionsSelection) {
        batchScopePopUp.selectItem(at: selection.batchScope.rawValue)
        select(formatPopUp, rawValue: selection.outputFormat.rawValue)
        bitratePopUp.selectItem(withTag: selection.bitrate ?? -1)
        sampleRatePopUp.selectItem(withTag: selection.sampleRate ?? -1)
        select(folderStructurePopUp, rawValue: selection.folderStructureMode.rawValue)
        select(applyModePopUp, rawValue: selection.applyMode.rawValue)
        select(templatePresetPopUp, rawValue: selection.templatePreset.rawValue)
        applyTokenOrder(normalizeCustomTokenOrder(selection.tokenOrder))
        updateFormatDependentControls()
        updateTemplateOptionsVisibility()
        saveFolderStructurePreferences()
    }

    private struct WarningSummaryItem {
        let message: String
        let count: Int
    }

    private struct WarningSummary {
        let items: [WarningSummaryItem]
        let totalCount: Int
    }

    private func summarizeWarnings(from results: [ConversionExecutionResult]) -> WarningSummary {
        var orderedMessages: [String] = []
        var counts: [String: Int] = [:]
        var totalCount = 0

        for result in results {
            guard let warning = result.warning else {
                continue
            }

            let lines = warning
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for line in lines {
                if counts[line] == nil {
                    orderedMessages.append(line)
                    counts[line] = 0
                }
                counts[line, default: 0] += 1
                totalCount += 1
            }
        }

        let items = orderedMessages.compactMap { message -> WarningSummaryItem? in
            guard let count = counts[message] else {
                return nil
            }
            return WarningSummaryItem(message: message, count: count)
        }

        return WarningSummary(items: items, totalCount: totalCount)
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
        let normalized = normalizeCustomTokenOrder(selectedCustomTokenOrder())
        applyTokenOrder(normalized)
        saveFolderStructurePreferences()
    }

    private func configureTokenOrderPopups() {
        for popup in customTokenPopups {
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

        let preset = TemplatePreset(rawValue: defaults.string(forKey: defaultsTemplatePresetKey) ?? "") ?? .yearArtistAlbum
        select(templatePresetPopUp, rawValue: preset.rawValue)

        let storedOrder = defaults.stringArray(forKey: defaultsTokenOrderKey) ?? []
        let parsed = storedOrder.compactMap(folderToken(fromStoredRawValue:))
        let initialOrder = parsed.isEmpty ? preset.defaultTokenOrder : parsed
        let normalizedOrder = normalizeCustomTokenOrder(initialOrder)
        applyTokenOrder(normalizedOrder)

        updateTemplateOptionsVisibility()
    }

    private func saveFolderStructurePreferences() {
        defaults.set(selectedFolderStructureMode().rawValue, forKey: defaultsFolderStructureModeKey)
        defaults.set(selectedTemplatePreset().rawValue, forKey: defaultsTemplatePresetKey)
        defaults.set(selectedTemplateApplyMode().rawValue, forKey: defaultsTemplateApplyModeKey)
        defaults.set(normalizeCustomTokenOrder(selectedCustomTokenOrder()).map(\.rawValue), forKey: defaultsTokenOrderKey)
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
        let normalized = normalizeCustomTokenOrder(order)
        let popups = customTokenPopups
        for (index, token) in normalized.enumerated() where index < popups.count {
            select(popups[index], rawValue: token.rawValue)
        }
    }

    private func selectedCustomTokenOrder() -> [FolderToken] {
        let rawValues = customTokenPopups.compactMap {
            $0.selectedItem?.representedObject as? String
        }
        return rawValues.compactMap(folderToken(fromStoredRawValue:))
    }

    private func normalizeCustomTokenOrder(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []

        for token in order.prefix(customTokenPopups.count) {
            if token.isDisabled {
                normalized.append(.disabled)
                continue
            }

            if !used.contains(token) {
                normalized.append(token)
                used.insert(token)
            }
        }

        while normalized.count < customTokenPopups.count {
            normalized.append(.disabled)
        }

        return Array(normalized.prefix(customTokenPopups.count))
    }

    private var customTokenPopups: [NSPopUpButton] {
        [tokenOrderPopUp1, tokenOrderPopUp2, tokenOrderPopUp3, tokenOrderPopUp4, tokenOrderPopUp5]
    }

    private func folderToken(fromStoredRawValue rawValue: String) -> FolderToken? {
        if rawValue == "artist" {
            return .albumArtist
        }
        return FolderToken(rawValue: rawValue)
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
        if conversionService == nil {
            convertButton.isEnabled = false
            convertButton.title = "CONVERT"
            ModernRetroTheme.updateButtonLayers(convertButton)
            updateToolbarIndicators(activity: .disabled, completion: .error)
            return
        }

        if isConversionRunning {
            convertButton.isEnabled = false
            convertButton.title = "CONVERT"
            ModernRetroTheme.updateButtonLayers(convertButton)
            updateToolbarIndicators(activity: .running, completion: .info)
            return
        }

        guard !loadedTracks.isEmpty else {
            convertButton.isEnabled = false
            convertButton.title = "CONVERT"
            ModernRetroTheme.updateButtonLayers(convertButton)
            updateToolbarIndicators(activity: .idle, completion: toolbarCompletionState)
            return
        }

        convertButton.isEnabled = true
        convertButton.title = "CONVERT"
        ModernRetroTheme.updateButtonLayers(convertButton)
        updateToolbarIndicators(activity: .idle, completion: toolbarCompletionState)
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
        return .yearArtistAlbum
    }

    private func selectedTemplateApplyMode() -> TemplateApplyMode {
        if let raw = applyModePopUp.selectedItem?.representedObject as? String,
           let mode = TemplateApplyMode(rawValue: raw) {
            return mode
        }
        return .applyAll
    }

    private func selectedTemplateConfig() -> TemplateConfig {
        let preset = selectedTemplatePreset()
        let tokenOrder: [FolderToken]
        if preset == .custom {
            let normalizedCustomOrder = normalizeCustomTokenOrder(selectedCustomTokenOrder())
            let enabledTokens = normalizedCustomOrder.filter { !$0.isDisabled }
            tokenOrder = enabledTokens.isEmpty ? TemplatePreset.yearArtistAlbum.defaultTokenOrder : enabledTokens
        } else {
            tokenOrder = preset.defaultTokenOrder
        }

        return TemplateConfig(
            preset: preset,
            tokenOrder: tokenOrder
        )
    }

    private func albumGroupKey(for loadedTrack: LoadedTrack) -> AlbumGroupKey {
        AlbumGroupKey(
            artistBucket: resolvedAlbumArtistComponent(for: loadedTrack),
            album: resolvedAlbumComponent(for: loadedTrack),
            year: resolvedYearComponent(for: loadedTrack)
        )
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
            if $0.year != $1.year { return $0.year < $1.year }
            if $0.artistBucket != $1.artistBucket { return $0.artistBucket < $1.artistBucket }
            if $0.album != $1.album { return $0.album < $1.album }
            return false
        }

        var reviewed: [AlbumGroupKey: String] = [:]
        for (index, key) in sortedKeys.enumerated() {
            guard let representative = grouped[key] else { continue }
            let proposed = buildOutputSubpath(loadedTrack: representative, templateConfig: templateConfig)

            let alert = NSAlert()
            alert.messageText = "Album Folder \(index + 1) of \(sortedKeys.count)"
            alert.informativeText = "\(key.year) • \(key.artistBucket) • \(key.album)\nEdit destination subfolder:"
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
        let tokenOrder: [FolderToken]
        switch templateConfig.preset {
        case .artistYearAlbum:
            tokenOrder = [.albumArtist, .year, .album]
        case .yearArtistAlbum:
            tokenOrder = [.year, .albumArtist, .album]
        case .artistAlbumYear:
            tokenOrder = [.albumArtist, .album, .year]
        case .custom:
            tokenOrder = templateConfig.tokenOrder
        }

        let components = tokenOrder.compactMap { tokenValue(for: $0, loadedTrack: loadedTrack) }
        let fallbackPath = [
            resolvedYearComponent(for: loadedTrack),
            resolvedAlbumArtistComponent(for: loadedTrack),
            resolvedAlbumComponent(for: loadedTrack)
        ].joined(separator: "/")
        let rawPath = components.joined(separator: "/")

        return sanitizeRelativeSubpath(rawPath, fallback: fallbackPath)
    }

    private func tokenValue(for token: FolderToken, loadedTrack: LoadedTrack) -> String? {
        switch token {
        case .disabled:
            return nil
        case .year:
            return resolvedYearComponent(for: loadedTrack)
        case .albumArtist:
            return resolvedAlbumArtistComponent(for: loadedTrack)
        case .album:
            return resolvedAlbumComponent(for: loadedTrack)
        case .compilation:
            return isCompilationTrack(loadedTrack) ? "Compilation" : nil
        }
    }

    private func resolvedYearComponent(for loadedTrack: LoadedTrack) -> String {
        let value = loadedTrack.metadata.year.map(String.init) ?? ""
        return sanitizePathComponent(value, fallback: unknownYear)
    }

    private func resolvedAlbumArtistComponent(for loadedTrack: LoadedTrack) -> String {
        let value = normalizedMetadataValue(loadedTrack.metadata.albumArtist)
            ?? normalizedMetadataValue(loadedTrack.metadata.artist)
            ?? normalizedMetadataValue(loadedTrack.track.artist)
            ?? unknownArtist
        return sanitizePathComponent(value, fallback: unknownArtist)
    }

    private func resolvedAlbumComponent(for loadedTrack: LoadedTrack) -> String {
        let value = normalizedMetadataValue(loadedTrack.metadata.album)
            ?? normalizedMetadataValue(loadedTrack.track.album)
            ?? unknownAlbum
        return sanitizePathComponent(value, fallback: unknownAlbum)
    }

    private func isCompilationTrack(_ loadedTrack: LoadedTrack) -> Bool {
        loadedTrack.metadata.compilation == true
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            if let root = sourceRoot(for: track.fileURL) {
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

    private func sourceRoot(for trackURL: URL) -> URL? {
        sourceRootByTrackPath[trackPathKey(for: trackURL)]
    }

    private func preferredLoadDirectoryURL() -> URL? {
        validDirectoryURL(forDefaultsKey: defaultsLastLoadFolderPathKey)
            ?? validDirectoryURL(forDefaultsKey: defaultsLastConvertFolderPathKey)
    }

    private func preferredConvertDirectoryURL() -> URL? {
        validDirectoryURL(forDefaultsKey: defaultsLastConvertFolderPathKey)
            ?? validDirectoryURL(forDefaultsKey: defaultsLastLoadFolderPathKey)
    }

    private func saveLastLoadDirectory(_ directoryURL: URL) {
        defaults.set(directoryURL.path, forKey: defaultsLastLoadFolderPathKey)
    }

    private func saveLastConvertDirectory(_ directoryURL: URL) {
        defaults.set(directoryURL.path, forKey: defaultsLastConvertFolderPathKey)
    }

    private func validDirectoryURL(forDefaultsKey key: String) -> URL? {
        guard let path = defaults.string(forKey: key),
              !path.isEmpty
        else {
            return nil
        }

        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return directoryURL
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func setStatus(_ text: String) {
        statusField.stringValue = text
        updateLCD()
    }

    private func setLCDConversionStatus(
        _ text: String?,
        tone: ModernRetroTheme.StatusTone = .neutral,
        progress: Double? = nil
    ) {
        lcdSecondaryResetWorkItem?.cancel()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        lcdSecondaryStatusOverride = (trimmed?.isEmpty == false) ? trimmed : nil
        lcdSecondaryToneOverride = tone
        if let progress {
            lcdBarProgressOverride = max(0.0, min(progress, 1.0))
        }
        updateLCD()
    }

    private func scheduleClearLCDConversionStatus(after delay: TimeInterval, resetCompletionIndicator: Bool = false) {
        lcdSecondaryResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lcdSecondaryStatusOverride = nil
            self?.lcdSecondaryToneOverride = .neutral
            self?.lcdBarProgressOverride = 0
            if resetCompletionIndicator {
                self?.updateToolbarIndicators(activity: .idle, completion: .idle)
            }
            self?.updateLCD()
        }
        lcdSecondaryResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateLCD() {
        let selected = (tableView.selectedRow >= 0 && loadedTracks.indices.contains(tableView.selectedRow)) ? loadedTracks[tableView.selectedRow] : nil
        lcdView.updateTrack(selected)
        if selected == nil {
            lcdView.setPrimaryStatus(statusField.stringValue)
        } else {
            lcdView.setPrimaryStatus(nil)
        }
        lcdView.setSecondaryStatus(lcdSecondaryStatusOverride, tone: lcdSecondaryToneOverride)

        if let status = lcdSecondaryStatusOverride {
            lcdView.setBarMode(
                .conversion(progress: lcdBarProgressOverride, text: status, tone: lcdSecondaryToneOverride),
                animated: true
            )
        } else {
            lcdView.setBarMode(.hidden, animated: true)
        }
    }
}

private final class ModernRowView: NSTableRowView {
    var rowIndex: Int = 0

    override func drawBackground(in dirtyRect: NSRect) {
        ModernRetroTheme.drawListRowBackground(rowIndex, in: dirtyRect)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        ModernRetroTheme.drawListRowSelection(in: dirtyRect)
    }
}

private final class TrackCellView: NSTableCellView {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateTextColors()
        }
    }

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
        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        updateTextColors()

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

    private func updateTextColors() {
        if backgroundStyle == .emphasized {
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.98)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        } else {
            titleLabel.textColor = ModernRetroTheme.textPrimary
            detailLabel.textColor = ModernRetroTheme.textSecondary
        }
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
