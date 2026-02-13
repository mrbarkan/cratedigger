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

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let openFolderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    private let playlistSortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private let outputFormats: [OutputFormat] = [.mp3, .aac, .alac, .flac, .wav, .aiff, .ogg, .opus]
    private let bitrateOptions = [-1, 96, 128, 160, 192, 256, 320]
    private let sampleRateOptions = [-1, 32000, 44100, 48000, 96000]
    private let unknownArtist = "Unknown Artist"
    private let unknownAlbum = "Unknown Album"
    private let unknownYear = "Unknown Year"
    private var selectedArtworkMaxDimension: Int?

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
        let inspectorPreferredWidth = inspectorViewController.view.widthAnchor.constraint(equalToConstant: 380)
        inspectorPreferredWidth.priority = .defaultHigh
        inspectorPreferredWidth.isActive = true
        inspectorViewController.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

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
        ModernRetroTheme.updateButtonLayers(previousButton)
        ModernRetroTheme.updateButtonLayers(playPauseButton)
        ModernRetroTheme.updateButtonLayers(nextButton)
        updateToolbarIndicators(activity: toolbarActivityState, completion: toolbarCompletionState)
        lcdView.layoutSubtreeIfNeeded()
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
        let adjustedWidth = max(frame.width, minSize.width)
        let adjustedHeight = max(frame.height, minSize.height)
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

    private func configurePlaylistSortPopUp() {
        playlistSortPopUp.removeAllItems()
        for mode in PlaylistSortMode.allCases {
            playlistSortPopUp.addItem(withTitle: mode.title)
            playlistSortPopUp.lastItem?.representedObject = mode.rawValue
        }
        select(playlistSortPopUp, rawValue: playlistSortMode.rawValue)
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
        playlistSortPopUp.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        playlistSortPopUp.widthAnchor.constraint(equalToConstant: 158).isActive = true

        let sortStack = NSStackView(views: [sortLabel, playlistSortPopUp])
        sortStack.orientation = .horizontal
        sortStack.alignment = .centerY
        sortStack.spacing = 6

        let leftStack = NSStackView(views: [openFolderButton, convertButton, sortStack])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

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
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

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
            lcdView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            lcdView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            lcdView.heightAnchor.constraint(equalToConstant: 56),

            transportButtons.trailingAnchor.constraint(lessThanOrEqualTo: lcdView.leadingAnchor, constant: -24),
            volumeStack.leadingAnchor.constraint(greaterThanOrEqualTo: lcdView.trailingAnchor, constant: 12),
            volumeStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            indicatorStack.leadingAnchor.constraint(greaterThanOrEqualTo: volumeStack.trailingAnchor, constant: 16),
            indicatorStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            indicatorStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -(ModernRetroTheme.contentInsets.right + 4))
        ])
        let preferredLCDWidth = lcdView.widthAnchor.constraint(equalToConstant: 460)
        preferredLCDWidth.priority = .defaultHigh
        preferredLCDWidth.isActive = true

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
        restoreArtworkResizePreference()
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
                    self.setStatus("No supported audio files found")
                    self.inspectorViewController.update(with: nil)
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.setStatus("Loaded \(self.loadedTracks.count) tracks")
                }
                self.updateConvertButtonState()
                self.updatePlaybackControls()
                self.playbackErrorMessage = nil
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
                self.playConversionCompletionSound()
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
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
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
            artworkMaxDimension: selectedArtworkMaxDimension,
            folderStructureMode: selectedFolderStructureMode(),
            applyMode: selectedTemplateApplyMode(),
            templatePreset: selectedTemplatePreset(),
            tokenOrder: normalizeCustomTokenOrder(selectedCustomTokenOrder())
        )
    }

    private func applyConversionOptionsSelection(_ selection: ConversionOptionsSelection) {
        batchScopePopUp.selectItem(at: selection.batchScope.rawValue)
        selectedArtworkMaxDimension = selection.artworkMaxDimension
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

    private func restoreArtworkResizePreference() {
        let stored = defaults.object(forKey: defaultsArtworkMaxDimensionKey) as? Int
        selectedArtworkMaxDimension = stored
    }

    private func saveArtworkResizePreference() {
        if let selectedArtworkMaxDimension {
            defaults.set(selectedArtworkMaxDimension, forKey: defaultsArtworkMaxDimensionKey)
        } else {
            defaults.removeObject(forKey: defaultsArtworkMaxDimensionKey)
        }
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
            artworkMode: .compatReembed,
            artworkMaxDimension: selectedArtworkMaxDimension
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
