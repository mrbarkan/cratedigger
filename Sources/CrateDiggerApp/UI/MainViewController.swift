import AppKit
import CrateDiggerCore

private enum PlaylistSortMode: String, CaseIterable {
    case manual
    case trackDiscAscending
    case trackDiscDescending
    case titleAscending
    case titleDescending
    case artistAscending
    case artistDescending
    case albumAscending
    case albumDescending
    case durationAscending
    case durationDescending

    var title: String {
        switch self {
        case .manual:
            return "Manual Order"
        case .trackDiscAscending:
            return "Track/Disc ↑"
        case .trackDiscDescending:
            return "Track/Disc ↓"
        case .titleAscending:
            return "Title ↑"
        case .titleDescending:
            return "Title ↓"
        case .artistAscending:
            return "Artist ↑"
        case .artistDescending:
            return "Artist ↓"
        case .albumAscending:
            return "Album ↑"
        case .albumDescending:
            return "Album ↓"
        case .durationAscending:
            return "Duration ↑"
        case .durationDescending:
            return "Duration ↓"
        }
    }
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
    var onFirstLoadedLibrary: (() -> Void)?

    private let artworkService = ArtworkService()
    private let toolLocator = ExternalToolLocator()
    private let outputPathPlanner = OutputPathPlanner()
    private var libraryScanService: LibraryScanService!

    private var conversionService: ConversionService?
    private var conversionServiceInitializationError: Error?
    private var appReadiness = AppReadiness(
        playback: .ready("Ready"),
        metadataProbe: .limited("Detecting"),
        conversion: .limited("Detecting")
    )
    private var scanTask: Task<Void, Never>?
    private var lastConversionReport: ConversionReport?

    private var loadedTracks: [LoadedTrack] = []
    private var sourceRootByTrackPath: [String: URL] = [:]
    private lazy var playbackService: PlaybackServiceProtocol = PlaybackService()
    private var playbackState: PlaybackState = .idle
    private var playbackCurrentIndex: Int?
    private var playbackCurrentTime: Double = 0
    private var playbackDuration: Double = 0
    private var playbackErrorMessage: String?
    private var playbackVolume: Double = 0.8
    private var suppressSelectionDrivenPlayback = false
    private var keyEventMonitor: Any?
    private var playlistSortMode: PlaylistSortMode = .trackDiscAscending
    private var hasAppliedStartupLayout = false
    private var hasReportedFirstLoadedLibrary = false
    private var conversionSelection = ConversionOptionsSelection(
        batchScope: .selectedTracks,
        outputFormat: .aac,
        bitrate: 192,
        sampleRate: 44_100,
        artworkMaxDimension: nil,
        folderStructureMode: .sourceRelative,
        applyMode: .applyAll,
        templatePreset: .yearArtistAlbum,
        tokenOrder: TemplatePreset.yearArtistAlbum.defaultTokenOrder
    )

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let playlistContainerView = NSView()
    private let splitView = NSSplitView()
    private let leftContainerView = NSView()
    private let inspectorContainerView = NSView()
    private let emptyStateView = NSView()
    private let emptyStateTitleField = NSTextField(labelWithString: "Load a folder to begin")
    private let emptyStateMessageField = NSTextField(labelWithString: "Choose one or more music folders to scan, preview, and convert.")
    private let emptyStateSpinner = NSProgressIndicator()
    private let openFolderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    private let playlistSortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusField = NSTextField(labelWithString: "Load a folder to begin")
    private let readinessField = NSTextField(labelWithString: "")
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    private let convertButton = NSButton(title: "CONVERT", target: nil, action: nil)
    private let previousButton = NSButton(title: "◀◀", target: nil, action: nil)
    private let playPauseButton = NSButton(title: "PLAY", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶▶", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
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
    private var completionSound: NSSound?

    private let inspectorViewController = TrackInspectorViewController()
    private var currentWindowLayoutMode: WindowLayoutMode = .workspace
    private var appliedWindowLayoutMode: WindowLayoutMode?
    private var inspectorPreferredWidthConstraint: NSLayoutConstraint!
    private var inspectorMinimumWidthConstraint: NSLayoutConstraint!
    private var inspectorCollapsedWidthConstraint: NSLayoutConstraint!
    private let outputFormats: [OutputFormat] = [.mp3, .aac, .alac, .flac, .wav, .aiff, .ogg, .opus]
    private let bitrateOptions = [-1, 96, 128, 160, 192, 256, 320]
    private let sampleRateOptions = [-1, 32000, 44100, 48000, 96000]

    private let defaults = UserDefaults.standard
    private let defaultsFolderStructureModeKey = "CrateDigger.folderStructureMode"
    private let defaultsTemplatePresetKey = "CrateDigger.templatePreset"
    private let defaultsTemplateApplyModeKey = "CrateDigger.templateApplyMode"
    private let defaultsTokenOrderKey = "CrateDigger.templateTokenOrder"
    private let defaultsLastLoadFolderPathKey = "CrateDigger.lastLoadFolderPath"
    private let defaultsLastConvertFolderPathKey = "CrateDigger.lastConvertFolderPath"
    private let defaultsArtworkMaxDimensionKey = "CrateDigger.artworkMaxDimension"
    private let tableDragType = NSPasteboard.PasteboardType("com.cratedigger.table-track-row")

    deinit {
        scanTask?.cancel()
        lcdSecondaryResetWorkItem?.cancel()
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ModernRetroTheme.surfaceBase.cgColor

        addChild(inspectorViewController)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        leftContainerView.translatesAutoresizingMaskIntoConstraints = false
        configureLeftPane(in: leftContainerView)

        inspectorContainerView.translatesAutoresizingMaskIntoConstraints = false
        inspectorViewController.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainerView.addSubview(inspectorViewController.view)
        NSLayoutConstraint.activate([
            inspectorViewController.view.topAnchor.constraint(equalTo: inspectorContainerView.topAnchor),
            inspectorViewController.view.leadingAnchor.constraint(equalTo: inspectorContainerView.leadingAnchor),
            inspectorViewController.view.trailingAnchor.constraint(equalTo: inspectorContainerView.trailingAnchor),
            inspectorViewController.view.bottomAnchor.constraint(equalTo: inspectorContainerView.bottomAnchor)
        ])

        splitView.addArrangedSubview(leftContainerView)
        splitView.addArrangedSubview(inspectorContainerView)

        inspectorPreferredWidthConstraint = inspectorContainerView.widthAnchor.constraint(equalToConstant: 340)
        inspectorPreferredWidthConstraint.priority = .defaultHigh
        inspectorMinimumWidthConstraint = inspectorContainerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        inspectorCollapsedWidthConstraint = inspectorContainerView.widthAnchor.constraint(equalToConstant: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

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
            leftContainerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 38)
        ])

        configureConversionOptions()
        configureServices()
        applyWindowLayoutMode(.workspace)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        ModernRetroTheme.updateButtonLayers(openFolderButton)
        ModernRetroTheme.updateButtonLayers(convertButton)
        ModernRetroTheme.updateButtonLayers(previousButton)
        ModernRetroTheme.updateButtonLayers(playPauseButton)
        ModernRetroTheme.updateButtonLayers(nextButton)
        updateToolbarIndicators(activity: toolbarActivityState, completion: toolbarCompletionState)
        lcdView.layoutSubtreeIfNeeded()
        applyPendingWindowLayoutModeIfNeeded(animated: false)
        updateLCD()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyboardMonitorIfNeeded()
        fitWindowStartupLayoutIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func fitWindowStartupLayoutIfNeeded() {
        guard !hasAppliedStartupLayout else { return }
        guard let window = view.window else { return }

        var frame = window.frame
        let minSize = window.minSize
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let maxWidth = max(minSize.width, visibleFrame.width - 24)
        let maxHeight = max(minSize.height, visibleFrame.height - 24)
        let adjustedWidth = min(max(frame.width, minSize.width), maxWidth)
        let adjustedHeight = min(max(frame.height, minSize.height), maxHeight)
        if adjustedWidth != frame.width || adjustedHeight != frame.height {
            frame.size = NSSize(width: adjustedWidth, height: adjustedHeight)
            window.setFrame(frame, display: true, animate: false)
        }

        view.layoutSubtreeIfNeeded()
        topBar.layoutSubtreeIfNeeded()
        ModernRetroTheme.updateButtonLayers(openFolderButton)
        ModernRetroTheme.updateButtonLayers(convertButton)
        ModernRetroTheme.updateButtonLayers(previousButton)
        ModernRetroTheme.updateButtonLayers(playPauseButton)
        ModernRetroTheme.updateButtonLayers(nextButton)
        hasAppliedStartupLayout = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            ModernRetroTheme.updateButtonLayers(self.openFolderButton)
            ModernRetroTheme.updateButtonLayers(self.convertButton)
            ModernRetroTheme.updateButtonLayers(self.previousButton)
            ModernRetroTheme.updateButtonLayers(self.playPauseButton)
            ModernRetroTheme.updateButtonLayers(self.nextButton)
        }
    }

    func applyWindowLayoutMode(_ mode: WindowLayoutMode) {
        currentWindowLayoutMode = mode
        applyPendingWindowLayoutModeIfNeeded(animated: mode == .workspace)
    }

    private func applyPendingWindowLayoutModeIfNeeded(animated: Bool) {
        guard isViewLoaded else { return }
        guard appliedWindowLayoutMode != currentWindowLayoutMode else { return }

        let collapsesInspector = false  // legacy view; new chassis uses fixed layout
        inspectorPreferredWidthConstraint.isActive = !collapsesInspector
        inspectorMinimumWidthConstraint.isActive = !collapsesInspector
        inspectorCollapsedWidthConstraint.isActive = collapsesInspector
        inspectorContainerView.isHidden = collapsesInspector

        splitView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()

        guard splitView.subviews.count > 1 else {
            appliedWindowLayoutMode = currentWindowLayoutMode
            return
        }

        if collapsesInspector {
            splitView.setPosition(splitView.bounds.width, ofDividerAt: 0)
        } else {
            let desiredLeftWidth = max(440, splitView.bounds.width - 340)
            splitView.setPosition(min(desiredLeftWidth, splitView.bounds.width - 300), ofDividerAt: 0)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.splitView.animator().layoutSubtreeIfNeeded()
            }
        }

        appliedWindowLayoutMode = currentWindowLayoutMode
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
        guard let tableColumn else { return nil }
        let loadedTrack = loadedTracks[row]

        if tableColumn.identifier.rawValue == "TrackNumberColumn" {
            let identifier = NSUserInterfaceItemIdentifier("TrackNumberCellView")
            let cell: TrackNumberCellView
            if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? TrackNumberCellView {
                cell = reusable
            } else {
                cell = TrackNumberCellView(frame: .zero)
                cell.identifier = identifier
            }
            cell.configure(positionText: trackPositionText(for: loadedTrack))
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("TrackCellView")
        let cell: TrackCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? TrackCellView {
            cell = reusable
        } else {
            cell = TrackCellView(frame: .zero)
            cell.identifier = identifier
        }

        let thumbnail = loadedTrack.track.artworkHash.flatMap {
            artworkService.generateThumbnail(artworkHash: $0, size: CGSize(width: 36, height: 36))
        }

        cell.configure(track: loadedTrack.track, thumbnail: thumbnail)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: tableDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else {
            return []
        }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard info.draggingSource as? NSTableView === tableView else {
            return false
        }

        if playlistSortMode != .manual {
            playlistSortMode = .manual
            select(playlistSortPopUp, rawValue: PlaylistSortMode.manual.rawValue)
        }

        let movingRows = tableView.selectedRowIndexes
        guard !movingRows.isEmpty else {
            return false
        }

        let movedTracks = movingRows.compactMap { loadedTracks.indices.contains($0) ? loadedTracks[$0] : nil }
        guard !movedTracks.isEmpty else {
            return false
        }

        let playbackTrackPath = currentPlaybackTrackPath()
        let wasPlaying = playbackState == .playing || playbackState == .loading
        let preservedTime = playbackCurrentTime

        var insertionIndex = row
        for index in movingRows.reversed() where loadedTracks.indices.contains(index) {
            loadedTracks.remove(at: index)
            if index < insertionIndex {
                insertionIndex -= 1
            }
        }

        insertionIndex = max(0, min(insertionIndex, loadedTracks.count))
        loadedTracks.insert(contentsOf: movedTracks, at: insertionIndex)

        tableView.reloadData()
        let movedIndexes = IndexSet(integersIn: insertionIndex..<(insertionIndex + movedTracks.count))
        tableView.selectRowIndexes(movedIndexes, byExtendingSelection: false)

        rebuildPlaybackQueueForCurrentOrder(
            preferredTrackPath: playbackTrackPath,
            autoPlay: wasPlaying,
            preserveTime: preservedTime
        )
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, loadedTracks.indices.contains(tableView.selectedRow) else {
            inspectorViewController.update(with: nil)
            updateConvertButtonState()
            updatePlaybackControls()
            updateLCD()
            return
        }

        inspectorViewController.update(with: loadedTracks[tableView.selectedRow])
        updateConvertButtonState()
        if !suppressSelectionDrivenPlayback {
            updatePlaybackControls()
        }
        updateLCD()
    }

    private func configureLeftPane(in container: NSView) {
        let numberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrackNumberColumn"))
        numberColumn.title = "#"
        numberColumn.width = 88
        numberColumn.minWidth = 74
        numberColumn.maxWidth = 108
        numberColumn.resizingMask = .autoresizingMask

        let trackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrackColumn"))
        trackColumn.title = "Tracks"
        trackColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(numberColumn)
        tableView.addTableColumn(trackColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.target = self
        tableView.doubleAction = #selector(playSelectedTrackFromDoubleClick)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.registerForDraggedTypes([tableDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityLabel("Track list")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.scrollerStyle = .legacy
        ModernRetroTheme.styleListContainer(scrollView: scrollView, tableView: tableView)

        configureEmptyStateView()

        playlistContainerView.translatesAutoresizingMaskIntoConstraints = false
        playlistContainerView.addSubview(scrollView)
        playlistContainerView.addSubview(emptyStateView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: playlistContainerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: playlistContainerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: playlistContainerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: playlistContainerView.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: playlistContainerView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: playlistContainerView.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: playlistContainerView.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: playlistContainerView.trailingAnchor, constant: -24)
        ])

        let contentStack = NSStackView(views: [playlistContainerView])
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: ModernRetroTheme.contentInsets.top),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ModernRetroTheme.contentInsets.left),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ModernRetroTheme.contentInsets.right),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -ModernRetroTheme.contentInsets.bottom),
            playlistContainerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        updateEmptyState(
            title: "Load a folder to begin",
            message: "Choose one or more music folders to scan, preview, and convert.",
            showsSpinner: false
        )
    }

    private func stylePopUp(_ popUp: NSPopUpButton) {
        ModernRetroTheme.stylePopUp(popUp)
    }

    private func configurePlaylistSortPopUp() {
        playlistSortPopUp.removeAllItems()
        for mode in PlaylistSortMode.allCases {
            playlistSortPopUp.addItem(withTitle: mode.title)
            playlistSortPopUp.lastItem?.representedObject = mode.rawValue
        }
        select(playlistSortPopUp, rawValue: playlistSortMode.rawValue)
    }

    private func select(_ popUp: NSPopUpButton, rawValue: String) {
        for item in popUp.itemArray where (item.representedObject as? String) == rawValue {
            popUp.select(item)
            return
        }
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

        let sortLabel = NSTextField(labelWithString: "ORDER")
        sortLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        sortLabel.textColor = ModernRetroTheme.textSecondary

        playlistSortPopUp.target = self
        playlistSortPopUp.action = #selector(playlistSortChanged)
        stylePopUp(playlistSortPopUp)
        configurePlaylistSortPopUp()
        playlistSortPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        playlistSortPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true

        let sortStack = NSStackView(views: [sortLabel, playlistSortPopUp])
        sortStack.orientation = .horizontal
        sortStack.alignment = .centerY
        sortStack.spacing = 6
        sortStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let leftStack = NSStackView(views: [openFolderButton, convertButton, sortStack])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previousButton.target = self
        previousButton.action = #selector(previousTrackAction)
        ModernRetroTheme.styleSecondaryButton(previousButton)
        styleTransportButton(previousButton, symbol: "backward.fill", accessibilityLabel: "Previous")
        previousButton.toolTip = "Previous (Command+Up)"

        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseAction)
        ModernRetroTheme.styleSecondaryButton(playPauseButton)
        styleTransportButton(playPauseButton, symbol: "play.fill", accessibilityLabel: "Play")
        playPauseButton.toolTip = "Play/Pause (Space)"

        nextButton.target = self
        nextButton.action = #selector(nextTrackAction)
        ModernRetroTheme.styleSecondaryButton(nextButton)
        styleTransportButton(nextButton, symbol: "forward.fill", accessibilityLabel: "Next")
        nextButton.toolTip = "Next (Command+Down)"
        [previousButton, playPauseButton, nextButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 34).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.doubleValue = playbackVolume

        let transportButtons = NSStackView(views: [previousButton, playPauseButton, nextButton])
        transportButtons.orientation = .horizontal
        transportButtons.alignment = .centerY
        transportButtons.spacing = 8
        transportButtons.translatesAutoresizingMaskIntoConstraints = false
        transportButtons.setContentCompressionResistancePriority(.required, for: .horizontal)

        let volumeIcon = NSTextField(labelWithString: "VOL")
        volumeIcon.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        volumeIcon.textColor = ModernRetroTheme.textSecondary

        let volumeStack = NSStackView(views: [volumeIcon, volumeSlider])
        volumeStack.orientation = .horizontal
        volumeStack.alignment = .centerY
        volumeStack.spacing = 6
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        volumeStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        volumeSlider.widthAnchor.constraint(equalToConstant: 60).isActive = true

        configureIndicator(activityIndicatorView)
        configureIndicator(completionIndicatorView)
        let indicatorStack = NSStackView(views: [activityIndicatorView, completionIndicatorView])
        indicatorStack.orientation = .horizontal
        indicatorStack.alignment = .centerY
        indicatorStack.spacing = 8
        indicatorStack.translatesAutoresizingMaskIntoConstraints = false

        lcdView.translatesAutoresizingMaskIntoConstraints = false
        lcdView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lcdView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        topBar.addSubview(leftStack)
        topBar.addSubview(transportButtons)
        topBar.addSubview(lcdView)
        topBar.addSubview(volumeStack)
        topBar.addSubview(indicatorStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: ModernRetroTheme.toolbarClusterLeadingInset),
            leftStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            transportButtons.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 16),
            transportButtons.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            lcdView.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            lcdView.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            lcdView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            lcdView.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            lcdView.heightAnchor.constraint(equalToConstant: 56),

            transportButtons.trailingAnchor.constraint(lessThanOrEqualTo: lcdView.leadingAnchor, constant: -16),
            volumeStack.leadingAnchor.constraint(greaterThanOrEqualTo: lcdView.trailingAnchor, constant: 10),
            volumeStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            indicatorStack.leadingAnchor.constraint(greaterThanOrEqualTo: volumeStack.trailingAnchor, constant: 12),
            indicatorStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            indicatorStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -(ModernRetroTheme.contentInsets.right + 4))
        ])
        let preferredLCDWidth = lcdView.widthAnchor.constraint(equalToConstant: 320)
        preferredLCDWidth.priority = .defaultHigh
        preferredLCDWidth.isActive = true

        openFolderButton.setAccessibilityLabel("Load folder")
        openFolderButton.setAccessibilityHelp("Choose one or more folders to scan for audio tracks.")
        convertButton.setAccessibilityLabel("Convert tracks")
        convertButton.setAccessibilityHelp("Open conversion settings for the selected or loaded tracks.")
        playlistSortPopUp.setAccessibilityLabel("Track order")
        volumeSlider.setAccessibilityLabel("Playback volume")
        previousButton.setAccessibilityHelp("Move to the previous track.")
        playPauseButton.setAccessibilityHelp("Play or pause the current track.")
        nextButton.setAccessibilityHelp("Move to the next track.")

        lcdView.onTimelineScrub = { [weak self] progress in
            guard let self, self.playbackDuration > 0 else { return }
            let target = progress * self.playbackDuration
            self.playbackService.seek(toSeconds: target)
        }

        updateToolbarIndicators(activity: .idle, completion: .idle)
        updatePlaybackControls()
    }

    private func styleTransportButton(_ button: NSButton, symbol: String, accessibilityLabel: String) {
        let pointSize: CGFloat = 13
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.title = ""
        button.bezelStyle = .regularSquare
        button.contentTintColor = ModernRetroTheme.textPrimary
    }

    private func updateTransportButtonSymbol(_ button: NSButton, symbol: String, accessibilityLabel: String) {
        let pointSize: CGFloat = 13
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(configuration)
        button.toolTip = accessibilityLabel
    }

    private func configureBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        ModernRetroTheme.applyChromeMaterial(to: bottomBar)

        statusField.textColor = ModernRetroTheme.textSecondary
        statusField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Current status")

        readinessField.textColor = ModernRetroTheme.textSecondary
        readinessField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        readinessField.translatesAutoresizingMaskIntoConstraints = false
        readinessField.lineBreakMode = .byTruncatingHead
        readinessField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readinessField.setAccessibilityLabel("App readiness")

        detailsButton.target = self
        detailsButton.action = #selector(showLastConversionDetails)
        detailsButton.isHidden = true
        detailsButton.isBordered = false
        detailsButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        detailsButton.contentTintColor = ModernRetroTheme.accentInfo
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.setAccessibilityLabel("Show conversion details")

        bottomBar.addSubview(statusField)
        bottomBar.addSubview(readinessField)
        bottomBar.addSubview(detailsButton)

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
            statusField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -8),

            detailsButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: readinessField.leadingAnchor, constant: -12),

            readinessField.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -(ModernRetroTheme.contentInsets.right + 2)),
            readinessField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            readinessField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])

        updateReadinessField()
    }

    private func configureEmptyStateView() {
        emptyStateView.wantsLayer = true
        emptyStateView.layer?.backgroundColor = ModernRetroTheme.surfaceElevated.withAlphaComponent(0.92).cgColor
        emptyStateView.layer?.cornerRadius = 16
        emptyStateView.layer?.borderWidth = 1
        emptyStateView.layer?.borderColor = ModernRetroTheme.separator.withAlphaComponent(0.25).cgColor

        emptyStateTitleField.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        emptyStateTitleField.textColor = ModernRetroTheme.textPrimary
        emptyStateTitleField.alignment = .center

        emptyStateMessageField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyStateMessageField.textColor = ModernRetroTheme.textSecondary
        emptyStateMessageField.alignment = .center
        emptyStateMessageField.maximumNumberOfLines = 2
        emptyStateMessageField.lineBreakMode = .byWordWrapping

        emptyStateSpinner.style = .spinning
        emptyStateSpinner.controlSize = .regular
        emptyStateSpinner.isDisplayedWhenStopped = false
        emptyStateSpinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [emptyStateSpinner, emptyStateTitleField, emptyStateMessageField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: emptyStateView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor, constant: -24),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    private func updateEmptyState(title: String, message: String, showsSpinner: Bool) {
        emptyStateTitleField.stringValue = title
        emptyStateMessageField.stringValue = message
        emptyStateView.isHidden = !loadedTracks.isEmpty && !showsSpinner

        if showsSpinner {
            emptyStateSpinner.startAnimation(nil)
        } else {
            emptyStateSpinner.stopAnimation(nil)
        }
    }

    private func updateReadinessField() {
        readinessField.stringValue = appReadiness.summaryText
        let tones = [appReadiness.playback.tone, appReadiness.metadataProbe.tone, appReadiness.conversion.tone]
        if tones.contains(.error) {
            readinessField.textColor = ModernRetroTheme.accentError
        } else if tones.contains(.warning) {
            readinessField.textColor = ModernRetroTheme.accentWarning
        } else {
            readinessField.textColor = ModernRetroTheme.textSecondary
        }
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
        restoreFolderStructurePreferences()
        restoreArtworkResizePreference()
        updateFormatDependentControls()
        updateConvertButtonState()
    }

    private func configureServices() {
        if let resolvedMetadataTool = toolLocator.resolveOptional(.ffprobe),
           let metadataProbe = try? MetadataProbeService(ffprobeExecutableURL: resolvedMetadataTool.url) {
            libraryScanService = LibraryScanService(artworkService: artworkService, metadataProbe: metadataProbe)
            appReadiness = AppReadiness(
                playback: .ready("Ready"),
                metadataProbe: .ready(readinessText(for: resolvedMetadataTool)),
                conversion: appReadiness.conversion
            )
        } else {
            libraryScanService = LibraryScanService(artworkService: artworkService, metadataProbe: nil)
            appReadiness = AppReadiness(
                playback: .ready("Ready"),
                metadataProbe: .limited("AVAsset fallback"),
                conversion: appReadiness.conversion
            )
        }

        do {
            let service = try ConversionService(artworkPreparer: artworkService)
            conversionService = service
            conversionServiceInitializationError = nil
            appReadiness = AppReadiness(
                playback: appReadiness.playback,
                metadataProbe: appReadiness.metadataProbe,
                conversion: .ready(readinessText(for: service.resolvedTool))
            )
            updateToolbarIndicators(activity: .idle, completion: .idle)
        } catch {
            conversionServiceInitializationError = error
            setStatus("Conversion is unavailable until ffmpeg is bundled with the app or installed on this Mac.")
            appReadiness = AppReadiness(
                playback: appReadiness.playback,
                metadataProbe: appReadiness.metadataProbe,
                conversion: .unavailable("ffmpeg missing")
            )
            updateToolbarIndicators(activity: .disabled, completion: .error)
        }

        updateReadinessField()
        configurePlaybackBindings()
        playbackService.setVolume(playbackVolume)
    }

    private func configurePlaybackBindings() {
        playbackService.onCurrentIndexChange = { [weak self] index in
            guard let self else { return }
            self.playbackCurrentIndex = index
            self.syncSelectionToPlaybackIndex(index)
            self.updatePlaybackControls()
            self.updateLCD()
        }

        playbackService.onStateChange = { [weak self] state in
            guard let self else { return }
            self.playbackState = state
            self.updatePlaybackControls()
            self.updateLCD()
        }

        playbackService.onTimeChange = { [weak self] current, duration in
            guard let self else { return }
            self.playbackCurrentTime = current
            self.playbackDuration = duration
            self.updatePlaybackControls()
            self.updateLCD()
        }

        playbackService.onError = { [weak self] message in
            guard let self else { return }
            self.playbackErrorMessage = message
            self.setStatus("Playback warning: \(message)")
            self.updateLCD()
        }
    }

    private func loadTracks(from folderURLs: [URL]) {
        let uniqueRoots = deduplicatedRoots(from: folderURLs)
        guard !uniqueRoots.isEmpty else {
            return
        }

        playbackService.load(queue: [], startIndex: 0, autoPlay: false)
        playbackState = .idle
        playbackCurrentIndex = nil
        playbackCurrentTime = 0
        playbackDuration = 0
        updatePlaybackControls()

        let folderSummary = uniqueRoots.count == 1
            ? uniqueRoots[0].lastPathComponent
            : "\(uniqueRoots.count) folders"
        loadedTracks = []
        sourceRootByTrackPath = [:]
        tableView.reloadData()
        inspectorViewController.update(with: nil)
        updateEmptyState(
            title: "Scanning \(folderSummary)",
            message: "CrateDigger is indexing the selected folders and reading artwork and metadata.",
            showsSpinner: true
        )
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
                self.applyPlaylistSort(mode: self.playlistSortMode, preservePlaybackOrder: false)
                self.tableView.reloadData()

                if self.loadedTracks.isEmpty {
                    self.setStatus("No supported audio files were found in the selected folders.")
                    self.updateEmptyState(
                        title: "No supported audio files found",
                        message: "Try another folder or confirm the files are in a supported format such as MP3, AAC, FLAC, WAV, AIFF, OGG, OPUS, or CAF.",
                        showsSpinner: false
                    )
                    self.inspectorViewController.update(with: nil)
                } else {
                    self.reportFirstLoadedLibraryIfNeeded()
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.setStatus("Loaded \(self.loadedTracks.count) tracks")
                    self.updateEmptyState(title: "", message: "", showsSpinner: false)
                }
                self.updateConvertButtonState()
                self.updatePlaybackControls()
                self.playbackErrorMessage = nil
                self.updateLCD()
            }
        }
    }

    private func reportFirstLoadedLibraryIfNeeded() {
        guard !hasReportedFirstLoadedLibrary else { return }
        guard !loadedTracks.isEmpty else { return }

        hasReportedFirstLoadedLibrary = true
        onFirstLoadedLibrary?()
    }

    private func scanFolders(_ roots: [URL]) async -> MultiRootScanResult {
        guard let libraryScanService else {
            return MultiRootScanResult(tracks: [], sourceRootByTrackPath: [:])
        }

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

        let sortedTracks = mergedTracks.sorted {
            $0.track.fileURL.path.localizedCaseInsensitiveCompare($1.track.fileURL.path) == .orderedAscending
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

    private func syncSelectionToPlaybackIndex(_ index: Int?) {
        guard let index, loadedTracks.indices.contains(index) else { return }
        guard tableView.selectedRow != index else { return }

        suppressSelectionDrivenPlayback = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        suppressSelectionDrivenPlayback = false
        inspectorViewController.update(with: loadedTracks[index])
    }

    @objc private func playSelectedTrackFromDoubleClick() {
        guard tableView.clickedRow >= 0 else { return }
        if tableView.selectedRow != tableView.clickedRow {
            tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
        }
        startPlaybackFromSelection(autoPlay: true)
    }

    @objc private func playPauseAction() {
        if playbackCurrentIndex == nil || playbackState == .idle || playbackState == .ended || isFailureState(playbackState) {
            startPlaybackFromSelection(autoPlay: true)
            return
        }

        if let selectedIndex = selectedTrackIndex(),
           selectedIndex != playbackCurrentIndex {
            startPlaybackFromSelection(autoPlay: true)
            return
        }

        playbackService.togglePlayPause()
    }

    @objc private func previousTrackAction() {
        playbackService.previous()
    }

    @objc private func nextTrackAction() {
        playbackService.next()
    }

    @objc private func volumeSliderChanged() {
        playbackVolume = volumeSlider.doubleValue
        playbackService.setVolume(playbackVolume)
    }

    private func startPlaybackFromSelection(autoPlay: Bool) {
        guard !loadedTracks.isEmpty else {
            setStatus("Load tracks before playback.")
            return
        }

        let index = selectedTrackIndex() ?? 0
        let queueItems = queueItemsFromLoadedTracks()
        playbackService.load(queue: queueItems, startIndex: index, autoPlay: autoPlay)
    }

    private func selectedTrackIndex() -> Int? {
        let selected = tableView.selectedRow
        guard selected >= 0, loadedTracks.indices.contains(selected) else {
            return nil
        }
        return selected
    }

    @objc private func playlistSortChanged() {
        let selectedMode = selectedPlaylistSortMode()
        playlistSortMode = selectedMode
        applyPlaylistSort(mode: selectedMode)
    }

    private func selectedPlaylistSortMode() -> PlaylistSortMode {
        if let rawValue = playlistSortPopUp.selectedItem?.representedObject as? String,
           let mode = PlaylistSortMode(rawValue: rawValue) {
            return mode
        }
        return .trackDiscAscending
    }

    private func applyPlaylistSort(mode: PlaylistSortMode, preservePlaybackOrder: Bool = true) {
        guard !loadedTracks.isEmpty else { return }

        let selectedTrackPaths = Set(
            tableView.selectedRowIndexes.compactMap { row in
                loadedTracks.indices.contains(row) ? trackPathKey(for: loadedTracks[row].track.fileURL) : nil
            }
        )

        let playbackTrackPath = currentPlaybackTrackPath()
        let wasPlaying = playbackState == .playing || playbackState == .loading
        let preservedTime = playbackCurrentTime

        switch mode {
        case .manual:
            break
        case .trackDiscAscending:
            loadedTracks.sort(by: { compareTrackDisc($0, $1, ascending: true) })
        case .trackDiscDescending:
            loadedTracks.sort(by: { compareTrackDisc($0, $1, ascending: false) })
        case .titleAscending:
            loadedTracks.sort(by: { compareString($0.track.title, $1.track.title, ascending: true, lhsFallback: $0, rhsFallback: $1) })
        case .titleDescending:
            loadedTracks.sort(by: { compareString($0.track.title, $1.track.title, ascending: false, lhsFallback: $0, rhsFallback: $1) })
        case .artistAscending:
            loadedTracks.sort(by: { compareString($0.track.artist, $1.track.artist, ascending: true, lhsFallback: $0, rhsFallback: $1) })
        case .artistDescending:
            loadedTracks.sort(by: { compareString($0.track.artist, $1.track.artist, ascending: false, lhsFallback: $0, rhsFallback: $1) })
        case .albumAscending:
            loadedTracks.sort(by: { compareString($0.track.album, $1.track.album, ascending: true, lhsFallback: $0, rhsFallback: $1) })
        case .albumDescending:
            loadedTracks.sort(by: { compareString($0.track.album, $1.track.album, ascending: false, lhsFallback: $0, rhsFallback: $1) })
        case .durationAscending:
            loadedTracks.sort(by: { compareDuration($0, $1, ascending: true) })
        case .durationDescending:
            loadedTracks.sort(by: { compareDuration($0, $1, ascending: false) })
        }

        tableView.reloadData()
        restoreSelection(forTrackPaths: selectedTrackPaths)

        if preservePlaybackOrder {
            rebuildPlaybackQueueForCurrentOrder(
                preferredTrackPath: playbackTrackPath,
                autoPlay: wasPlaying,
                preserveTime: preservedTime
            )
        }
    }

    private func compareTrackDisc(_ lhs: LoadedTrack, _ rhs: LoadedTrack, ascending: Bool) -> Bool {
        let lhsDisc = lhs.metadata.discNumber ?? Int.max
        let rhsDisc = rhs.metadata.discNumber ?? Int.max
        if lhsDisc != rhsDisc {
            return ascending ? (lhsDisc < rhsDisc) : (lhsDisc > rhsDisc)
        }

        let lhsTrack = lhs.metadata.trackNumber ?? Int.max
        let rhsTrack = rhs.metadata.trackNumber ?? Int.max
        if lhsTrack != rhsTrack {
            return ascending ? (lhsTrack < rhsTrack) : (lhsTrack > rhsTrack)
        }

        return compareString(lhs.track.title, rhs.track.title, ascending: ascending, lhsFallback: lhs, rhsFallback: rhs)
    }

    private func compareString(
        _ lhs: String,
        _ rhs: String,
        ascending: Bool,
        lhsFallback: LoadedTrack,
        rhsFallback: LoadedTrack
    ) -> Bool {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        if result != .orderedSame {
            return ascending ? (result == .orderedAscending) : (result == .orderedDescending)
        }

        let lhsPath = lhsFallback.track.fileURL.path
        let rhsPath = rhsFallback.track.fileURL.path
        let fallbackResult = lhsPath.localizedCaseInsensitiveCompare(rhsPath)
        return ascending ? (fallbackResult == .orderedAscending) : (fallbackResult == .orderedDescending)
    }

    private func compareDuration(_ lhs: LoadedTrack, _ rhs: LoadedTrack, ascending: Bool) -> Bool {
        let lhsDuration = lhs.track.durationSeconds
        let rhsDuration = rhs.track.durationSeconds
        if lhsDuration != rhsDuration {
            return ascending ? (lhsDuration < rhsDuration) : (lhsDuration > rhsDuration)
        }
        return compareString(lhs.track.title, rhs.track.title, ascending: ascending, lhsFallback: lhs, rhsFallback: rhs)
    }

    private func restoreSelection(forTrackPaths selectedTrackPaths: Set<String>) {
        guard !selectedTrackPaths.isEmpty else {
            if loadedTracks.indices.contains(tableView.selectedRow) {
                tableView.selectRowIndexes(IndexSet(integer: tableView.selectedRow), byExtendingSelection: false)
            }
            return
        }

        let indexes = IndexSet(loadedTracks.enumerated().compactMap { index, loaded in
            selectedTrackPaths.contains(trackPathKey(for: loaded.track.fileURL)) ? index : nil
        })

        if indexes.isEmpty {
            if !loadedTracks.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    private func queueItemsFromLoadedTracks() -> [PlaybackQueueItem] {
        loadedTracks.map { loaded in
            PlaybackQueueItem(
                url: loaded.track.fileURL,
                title: loaded.track.title,
                artist: loaded.track.artist,
                album: loaded.track.album,
                durationSeconds: loaded.track.durationSeconds
            )
        }
    }

    private func currentPlaybackTrackPath() -> String? {
        guard let index = playbackCurrentIndex else {
            return nil
        }

        if playbackService.queue.indices.contains(index) {
            return trackPathKey(for: playbackService.queue[index].url)
        }

        if loadedTracks.indices.contains(index) {
            return trackPathKey(for: loadedTracks[index].track.fileURL)
        }

        return nil
    }

    private func rebuildPlaybackQueueForCurrentOrder(
        preferredTrackPath: String?,
        autoPlay: Bool,
        preserveTime: Double
    ) {
        guard let preferredTrackPath else {
            return
        }
        guard !loadedTracks.isEmpty else {
            return
        }

        let queueItems = queueItemsFromLoadedTracks()
        guard let newIndex = loadedTracks.firstIndex(where: { trackPathKey(for: $0.track.fileURL) == preferredTrackPath }) else {
            return
        }

        playbackService.load(queue: queueItems, startIndex: newIndex, autoPlay: autoPlay)
        guard preserveTime > 0.25 else {
            return
        }

        let seekTime = preserveTime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.playbackService.seek(toSeconds: seekTime)
        }
    }

    private func trackPositionText(for loadedTrack: LoadedTrack) -> String {
        let trackNumber = loadedTrack.metadata.trackNumber
        let trackTotal = loadedTrack.metadata.trackTotal
        let discNumber = loadedTrack.metadata.discNumber
        let discTotal = loadedTrack.metadata.discTotal

        let trackText: String
        if let trackNumber {
            if let trackTotal, trackTotal > 0 {
                trackText = "\(trackNumber)/\(trackTotal)"
            } else {
                trackText = "\(trackNumber)"
            }
        } else {
            trackText = "—"
        }

        if let discNumber, discNumber > 0, (discNumber > 1 || (discTotal ?? 0) > 1) {
            if let discTotal, discTotal > 0 {
                return "D\(discNumber)/\(discTotal) • \(trackText)"
            }
            return "D\(discNumber) • \(trackText)"
        }

        return trackText
    }

    private func updatePlaybackControls() {
        let hasTracks = !loadedTracks.isEmpty

        previousButton.isEnabled = hasTracks && (playbackCurrentIndex ?? 0) > 0
        nextButton.isEnabled = hasTracks && ((playbackCurrentIndex ?? -1) < (loadedTracks.count - 1))

        let symbol: String
        let label: String
        switch playbackState {
        case .playing:
            symbol = "pause.fill"
            label = "Pause"
        case .loading:
            symbol = "hourglass"
            label = "Loading"
        default:
            symbol = "play.fill"
            label = "Play"
        }
        updateTransportButtonSymbol(playPauseButton, symbol: symbol, accessibilityLabel: label)
        playPauseButton.isEnabled = hasTracks

        volumeSlider.isEnabled = hasTracks
        if volumeSlider.cell?.isHighlighted != true {
            volumeSlider.doubleValue = playbackVolume
        }

        ModernRetroTheme.updateButtonLayers(previousButton)
        ModernRetroTheme.updateButtonLayers(playPauseButton)
        ModernRetroTheme.updateButtonLayers(nextButton)
    }

    private func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "0:00"
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func isFailureState(_ state: PlaybackState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private func installKeyboardMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyboardShortcut(event) ? nil : event
        }
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        guard view.window?.attachedSheet == nil else { return false }
        guard !(view.window?.firstResponder is NSTextView) else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "a",
           isPlaylistFocused() {
            tableView.selectAll(nil)
            return true
        }

        switch event.keyCode {
        case 49:
            if modifiers.isEmpty {
                playPauseAction()
                return true
            }
        case 36, 76:
            if modifiers.isEmpty {
                startPlaybackFromSelection(autoPlay: true)
                return true
            }
        case 126:
            if modifiers.contains(.command) {
                previousTrackAction()
                return true
            }
        case 125:
            if modifiers.contains(.command) {
                nextTrackAction()
                return true
            }
        case 123:
            if modifiers.contains(.option) {
                playbackService.seek(toSeconds: max(playbackCurrentTime - 5, 0))
                return true
            }
        case 124:
            if modifiers.contains(.option) {
                let target = playbackDuration > 0
                    ? min(playbackCurrentTime + 5, playbackDuration)
                    : playbackCurrentTime + 5
                playbackService.seek(toSeconds: target)
                return true
            }
        default:
            break
        }

        return false
    }

    private func isPlaylistFocused() -> Bool {
        guard let firstResponder = view.window?.firstResponder else {
            return false
        }

        if firstResponder === tableView || firstResponder === scrollView || firstResponder === scrollView.contentView {
            return true
        }

        if let responderView = firstResponder as? NSView {
            return responderView.isDescendant(of: tableView) || responderView.isDescendant(of: scrollView)
        }

        return false
    }

    private func trackPathKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @objc private func openFolderAction() {
        openFolder()
    }

    @objc private func convertSelectedTracks() {
        guard let conversionService else {
            setStatus(conversionServiceInitializationError?.localizedDescription ?? "Conversion is currently unavailable.")
            setLCDConversionStatus("Conversion unavailable", tone: .error, progress: 0)
            scheduleClearLCDConversionStatus(after: 2.0)
            return
        }

        guard !loadedTracks.isEmpty else {
            setStatus("Load a folder before converting.")
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
            setStatus("Select tracks or choose 'All Loaded Tracks' before converting.")
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
        var reviewedAlbumFolders: [AlbumFolderKey: String] = [:]
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
        var reservedDestinationPaths: Set<String> = []
        var collisionAdjustedOutputs = 0

        for loaded in tracksToConvert {
            let plannedOutput = outputPathPlanner.planDestination(
                for: loaded,
                preset: preset,
                destinationRoot: destinationFolder,
                sourceRoot: sourceRoot(for: loaded.track.fileURL),
                folderMode: folderMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders,
                reservedDestinationPaths: reservedDestinationPaths
            )
            reservedDestinationPaths.insert(trackPathKey(for: plannedOutput.destinationURL))
            if plannedOutput.collisionCount > 1 {
                collisionAdjustedOutputs += 1
            }
            let job = ConversionJob(
                sourceURL: loaded.track.fileURL,
                destinationURL: plannedOutput.destinationURL,
                metadata: loaded.metadata
            )
            jobs.append(job)
        }

        conversionService.clearQueue()
        _ = conversionService.enqueue(jobs, preset: preset)
        lastConversionReport = nil
        detailsButton.isHidden = true

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
                self.setStatus("Conversion complete. Success: \(completed), Failed: \(failed), Warnings: \(warningCount), Renamed: \(collisionAdjustedOutputs).")
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
                    "Finished • Success: \(completed) • Failed: \(failed) • Warnings: \(warningCount) • Renamed: \(collisionAdjustedOutputs)",
                    tone: completionTone,
                    progress: 1.0
                )
                self.playConversionCompletionSound()
                self.scheduleClearLCDConversionStatus(after: 3.8)
                self.updateConvertButtonState()

                var message = "Completed: \(completed)\nFailed: \(failed)\nRenamed to avoid collisions: \(collisionAdjustedOutputs)"
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
                let showsDetails = failed > 0 || warningCount > 0 || collisionAdjustedOutputs > 0
                self.lastConversionReport = ConversionReport(
                    title: "Conversion Finished",
                    statusLine: "Success: \(completed) • Failed: \(failed) • Warnings: \(warningCount) • Renamed: \(collisionAdjustedOutputs)",
                    details: message,
                    tone: completionTone,
                    showsDetailsButton: showsDetails
                )
                self.detailsButton.isHidden = !showsDetails
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
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
        conversionSelection
    }

    private func applyConversionOptionsSelection(_ selection: ConversionOptionsSelection) {
        conversionSelection = ConversionOptionsSelection(
            batchScope: selection.batchScope,
            outputFormat: selection.outputFormat,
            bitrate: selection.bitrate,
            sampleRate: selection.sampleRate,
            artworkMaxDimension: selection.artworkMaxDimension,
            folderStructureMode: selection.folderStructureMode,
            applyMode: selection.applyMode,
            templatePreset: selection.templatePreset,
            tokenOrder: normalizeCustomTokenOrder(selection.tokenOrder)
        )
        updateFormatDependentControls()
        saveFolderStructurePreferences()
        saveArtworkResizePreference()
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

    private func restoreFolderStructurePreferences() {
        let mode = FolderStructureMode(rawValue: defaults.string(forKey: defaultsFolderStructureModeKey) ?? "") ?? .sourceRelative
        let applyMode = TemplateApplyMode(rawValue: defaults.string(forKey: defaultsTemplateApplyModeKey) ?? "") ?? .applyAll
        let preset = TemplatePreset(rawValue: defaults.string(forKey: defaultsTemplatePresetKey) ?? "") ?? .yearArtistAlbum

        let storedOrder = defaults.stringArray(forKey: defaultsTokenOrderKey) ?? []
        let parsed = storedOrder.compactMap(folderToken(fromStoredRawValue:))
        let initialOrder = parsed.isEmpty ? preset.defaultTokenOrder : parsed
        conversionSelection = ConversionOptionsSelection(
            batchScope: conversionSelection.batchScope,
            outputFormat: conversionSelection.outputFormat,
            bitrate: conversionSelection.bitrate,
            sampleRate: conversionSelection.sampleRate,
            artworkMaxDimension: conversionSelection.artworkMaxDimension,
            folderStructureMode: mode,
            applyMode: applyMode,
            templatePreset: preset,
            tokenOrder: normalizeCustomTokenOrder(initialOrder)
        )
    }

    private func saveFolderStructurePreferences() {
        defaults.set(conversionSelection.folderStructureMode.rawValue, forKey: defaultsFolderStructureModeKey)
        defaults.set(conversionSelection.templatePreset.rawValue, forKey: defaultsTemplatePresetKey)
        defaults.set(conversionSelection.applyMode.rawValue, forKey: defaultsTemplateApplyModeKey)
        defaults.set(normalizeCustomTokenOrder(conversionSelection.tokenOrder).map(\.rawValue), forKey: defaultsTokenOrderKey)
    }

    private func normalizeCustomTokenOrder(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []

        for token in order.prefix(5) {
            if token.isDisabled {
                normalized.append(.disabled)
                continue
            }

            if !used.contains(token) {
                normalized.append(token)
                used.insert(token)
            }
        }

        while normalized.count < 5 {
            normalized.append(.disabled)
        }

        return Array(normalized.prefix(5))
    }

    private func restoreArtworkResizePreference() {
        let stored = defaults.object(forKey: defaultsArtworkMaxDimensionKey) as? Int
        conversionSelection = ConversionOptionsSelection(
            batchScope: conversionSelection.batchScope,
            outputFormat: conversionSelection.outputFormat,
            bitrate: conversionSelection.bitrate,
            sampleRate: conversionSelection.sampleRate,
            artworkMaxDimension: stored,
            folderStructureMode: conversionSelection.folderStructureMode,
            applyMode: conversionSelection.applyMode,
            templatePreset: conversionSelection.templatePreset,
            tokenOrder: conversionSelection.tokenOrder
        )
    }

    private func saveArtworkResizePreference() {
        if let artworkMaxDimension = conversionSelection.artworkMaxDimension {
            defaults.set(artworkMaxDimension, forKey: defaultsArtworkMaxDimensionKey)
        } else {
            defaults.removeObject(forKey: defaultsArtworkMaxDimensionKey)
        }
    }

    private func folderToken(fromStoredRawValue rawValue: String) -> FolderToken? {
        if rawValue == "artist" {
            return .albumArtist
        }
        return FolderToken(rawValue: rawValue)
    }

    private func updateFormatDependentControls() {
        let format = selectedOutputFormat()
        if isLosslessFormat(format), conversionSelection.bitrate != nil {
            conversionSelection = ConversionOptionsSelection(
                batchScope: conversionSelection.batchScope,
                outputFormat: conversionSelection.outputFormat,
                bitrate: nil,
                sampleRate: conversionSelection.sampleRate,
                artworkMaxDimension: conversionSelection.artworkMaxDimension,
                folderStructureMode: conversionSelection.folderStructureMode,
                applyMode: conversionSelection.applyMode,
                templatePreset: conversionSelection.templatePreset,
                tokenOrder: conversionSelection.tokenOrder
            )
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
            artworkMode: .compatReembed,
            artworkMaxDimension: conversionSelection.artworkMaxDimension
        )
    }

    private func selectedOutputFormat() -> OutputFormat {
        conversionSelection.outputFormat
    }

    private func selectedBitrate() -> Int? {
        conversionSelection.bitrate
    }

    private func selectedSampleRate() -> Int? {
        conversionSelection.sampleRate
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
        conversionSelection.folderStructureMode
    }

    private func selectedTemplatePreset() -> TemplatePreset {
        conversionSelection.templatePreset
    }

    private func selectedTemplateApplyMode() -> TemplateApplyMode {
        conversionSelection.applyMode
    }

    private func selectedTemplateConfig() -> FolderTemplateConfig {
        let preset = selectedTemplatePreset()
        let tokenOrder: [FolderToken]
        if preset == .custom {
            let normalizedCustomOrder = normalizeCustomTokenOrder(conversionSelection.tokenOrder)
            let enabledTokens = normalizedCustomOrder.filter { !$0.isDisabled }
            tokenOrder = enabledTokens.isEmpty ? TemplatePreset.yearArtistAlbum.defaultTokenOrder : enabledTokens
        } else {
            tokenOrder = preset.defaultTokenOrder
        }

        return FolderTemplateConfig(
            preset: preset,
            tokenOrder: tokenOrder
        )
    }

    private func albumGroupKey(for loadedTrack: LoadedTrack) -> AlbumFolderKey {
        outputPathPlanner.albumFolderKey(for: loadedTrack)
    }

    private func reviewAlbumFoldersPreflight(
        for tracks: [LoadedTrack],
        templateConfig: FolderTemplateConfig
    ) -> [AlbumFolderKey: String]? {
        var grouped: [AlbumFolderKey: LoadedTrack] = [:]
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

        let rows = sortedKeys.compactMap { key -> AlbumFolderReviewRow? in
            guard let representative = grouped[key] else {
                return nil
            }

            return AlbumFolderReviewRow(
                key: key,
                albumLabel: "\(key.year) • \(key.artistBucket) • \(key.album)",
                proposedSubpath: buildOutputSubpath(loadedTrack: representative, templateConfig: templateConfig)
            )
        }

        return presentAlbumFolderReviewSheet(rows: rows)
    }

    private func buildOutputSubpath(
        loadedTrack: LoadedTrack,
        templateConfig: FolderTemplateConfig
    ) -> String {
        outputPathPlanner.buildOutputSubpath(for: loadedTrack, templateConfig: templateConfig)
    }

    private func sourceRoot(for trackURL: URL) -> URL? {
        sourceRootByTrackPath[trackPathKey(for: trackURL)]
    }

    @objc private func showLastConversionDetails() {
        guard let report = lastConversionReport else {
            return
        }

        presentConversionSummarySheet(report: report)
    }

    private func presentAlbumFolderReviewSheet(rows: [AlbumFolderReviewRow]) -> [AlbumFolderKey: String]? {
        guard let hostWindow = view.window else {
            return nil
        }

        let controller = AlbumFolderReviewSheetController(rows: rows)
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Review Album Folders"
        sheetWindow.backgroundColor = ModernRetroTheme.surfaceBase
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.contentViewController = controller
        sheetWindow.standardWindowButton(.closeButton)?.isHidden = true

        var reviewedFolders: [AlbumFolderKey: String]?
        controller.onDecision = { [weak hostWindow, weak sheetWindow] reviewed in
            reviewedFolders = reviewed
            guard let hostWindow, let sheetWindow else { return }
            hostWindow.endSheet(sheetWindow)
            NSApp.stopModal()
        }

        hostWindow.beginSheet(sheetWindow, completionHandler: nil)
        NSApp.runModal(for: sheetWindow)
        return reviewedFolders
    }

    private func presentConversionSummarySheet(report: ConversionReport) {
        guard let hostWindow = view.window else {
            return
        }

        let controller = ConversionSummarySheetController(report: report)
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = report.title
        sheetWindow.backgroundColor = ModernRetroTheme.surfaceBase
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.contentViewController = controller
        sheetWindow.standardWindowButton(.closeButton)?.isHidden = true

        controller.onClose = { [weak hostWindow, weak sheetWindow] in
            guard let hostWindow, let sheetWindow else { return }
            hostWindow.endSheet(sheetWindow)
        }

        hostWindow.beginSheet(sheetWindow, completionHandler: nil)
    }

    private func readinessText(for tool: ResolvedExternalTool) -> String {
        switch tool.source {
        case .bundled:
            return "Bundled"
        case .explicitOverride:
            return "Override"
        case .environmentOverride:
            return "Environment"
        case .system:
            return "System"
        }
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

    private func playConversionCompletionSound() {
        if let namedSound = NSSound(named: NSSound.Name("Funk")) {
            completionSound = namedSound
            completionSound?.play()
            return
        }

        let fallbackURL = URL(fileURLWithPath: "/System/Library/Sounds/Funk.aiff")
        if let fallbackSound = NSSound(contentsOf: fallbackURL, byReference: true) {
            completionSound = fallbackSound
            completionSound?.play()
        }
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
        let playbackTrack = playbackCurrentIndex.flatMap { loadedTracks.indices.contains($0) ? loadedTracks[$0] : nil }
        let selectedTrack = (tableView.selectedRow >= 0 && loadedTracks.indices.contains(tableView.selectedRow))
            ? loadedTracks[tableView.selectedRow]
            : nil
        let activeTrack = playbackTrack ?? selectedTrack
        lcdView.updateTrack(activeTrack)

        if let status = lcdSecondaryStatusOverride {
            lcdView.setPrimaryStatus(nil)
            lcdView.setSecondaryStatus(status, tone: lcdSecondaryToneOverride)
            lcdView.setBarMode(
                .conversion(progress: lcdBarProgressOverride, text: status, tone: lcdSecondaryToneOverride),
                animated: isConversionRunning,
                accentAnimated: isConversionRunning
            )
            return
        }

        let playbackTone: ModernRetroTheme.StatusTone
        let playbackSecondary: String?
        let playbackPrimary: String?
        switch playbackState {
        case .idle:
            playbackTone = .neutral
            playbackSecondary = nil
            playbackPrimary = activeTrack == nil ? statusField.stringValue : nil
        case .loading:
            playbackTone = .info
            playbackSecondary = "Loading playback..."
            playbackPrimary = nil
        case .playing:
            playbackTone = .info
            playbackSecondary = "Playing • \(formatPlaybackTime(playbackCurrentTime)) / \(formatPlaybackTime(playbackDuration))"
            playbackPrimary = nil
        case .paused:
            playbackTone = .warning
            playbackSecondary = "Paused • \(formatPlaybackTime(playbackCurrentTime)) / \(formatPlaybackTime(playbackDuration))"
            playbackPrimary = nil
        case .ended:
            playbackTone = .success
            playbackSecondary = "End of queue • \(formatPlaybackTime(playbackDuration))"
            playbackPrimary = "End of Queue"
        case .failed(let message):
            playbackTone = .error
            playbackSecondary = playbackErrorMessage ?? message
            playbackPrimary = "Playback Error"
        }

        lcdView.setPrimaryStatus(playbackPrimary)
        lcdView.setSecondaryStatus(playbackSecondary, tone: playbackTone)

        if playbackDuration > 0 && playbackState != .idle && !isFailureState(playbackState) {
            let progress = max(0.0, min(playbackCurrentTime / playbackDuration, 1.0))
            let timelineText = "\(formatPlaybackTime(playbackCurrentTime)) / \(formatPlaybackTime(playbackDuration))"
            let playbackAnimated = playbackState == .playing
            lcdView.setBarMode(
                .timeline(progress: progress, text: timelineText, tone: playbackTone),
                animated: playbackAnimated,
                accentAnimated: playbackAnimated
            )
        } else {
            lcdView.setBarMode(.hidden, animated: false, accentAnimated: false)
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

private final class TrackNumberCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateTextColor()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateTextColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(positionText: String) {
        label.stringValue = positionText
    }

    private func updateTextColor() {
        if backgroundStyle == .emphasized {
            label.textColor = NSColor.white.withAlphaComponent(0.9)
        } else {
            label.textColor = ModernRetroTheme.textSecondary
        }
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
