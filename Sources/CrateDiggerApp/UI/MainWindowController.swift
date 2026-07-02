import AppKit
import CrateDiggerCore

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let hostingController = CarbonHostingController()

    /// The single shared view model — also used by the mini player.
    var model: LibraryViewModel { hostingController.model }
    private let prefs: PreferencesStore = .shared
    private var didApplyRestoredFrame = false

    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowFramePlanner.targetSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "CrateDigger"
        window.contentViewController = hostingController
        window.backgroundColor = .clear
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isRestorable = false

        super.init(window: window)

        window.delegate = self
        applyAppearancePreference()
        applyWindowPlan(context: .initialLaunch, animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceDidChange),
            name: AppearanceMode.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePresentGroupAlbumsSheet(_:)),
            name: .crateDiggerPresentGroupAlbumsSheet,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransferToDevice(_:)),
            name: NSNotification.Name("CrateDiggerTransferToDevice"),
            object: nil
        )
    }

    @objc private func handleTransferToDevice(_ note: Notification) {
        presentExternalDeviceTransferSheet()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func openFolder() {
        hostingController.model.openFolderViaPanel()
    }

    func loadFolders(_ urls: [URL]) {
        hostingController.model.loadFolders(urls)
    }

    func restoreLastSession() {
        hostingController.model.restoreLastFoldersIfPossible()
    }

    // MARK: - Selection-aware menu actions

    func currentSelectionURL() -> URL? {
        hostingController.model.selectedTrack?.track.fileURL
    }

    var hasLoadedTracks: Bool {
        !hostingController.model.index.allTracks.isEmpty
    }

    var isConversionRunning: Bool {
        hostingController.model.conversionProgress.isRunning
    }

    func presentConversionSheet() {
        // Reuse the same path the Cnvrt key uses so we get one entry point
        // rather than two slightly-divergent ones.
        guard contentViewController != nil else { return }
        let model = hostingController.model
        let controller = ConversionOptionsSheetController(
            initialSelection: model.makeInitialConversionSelection(),
            outputFormats: OutputFormat.allCases,
            bitrateOptions: [128, 160, 192, 256, 320],
            sampleRateOptions: [44_100, 48_000, 88_200, 96_000]
        )
        controller.onDecision = { [weak controller, weak model] selection in
            controller?.dismiss(nil)
            guard let selection, let model else { return }
            guard let host = NSApp.keyWindow?.contentViewController else { return }
            model.runConversion(selection: selection, presentingFrom: host)
        }
        hostingController.presentAsSheet(controller)
    }

    @objc private func handlePresentGroupAlbumsSheet(_ note: Notification) {
        guard let inputs = note.object as? GroupSheetInputs else { return }
        presentGroupAlbumsSheet(inputs: inputs)
    }

    func presentGroupAlbumsSheet(inputs: GroupSheetInputs) {
        guard contentViewController != nil else { return }
        let model = hostingController.model
        let controller = GroupAlbumsSheetController(
            kind: inputs.kind,
            name: inputs.name,
            originalYear: inputs.year,
            rows: inputs.rows,
            primaryKey: inputs.primaryKey
        )
        let groupID = inputs.id
        let groupKind = inputs.kind
        controller.onDecision = { [weak controller, weak model] result in
            controller?.dismiss(nil)
            guard let result, let model else { return }
            model.commitGroup(
                id: groupID,
                kind: groupKind,
                name: result.name,
                originalYear: result.originalYear,
                primaryKey: result.primaryKey,
                members: result.members
            )
        }
        hostingController.presentAsSheet(controller)
    }

    /// ⌘⇧T / the Sources "transfer here" button: send the current album to a saved
    /// device. One device → straight in; several → a lightweight device menu.
    /// Precise selections use the browser's right-click "Transfer to Device" instead.
    func presentExternalDeviceTransferSheet() {
        guard let contentView = contentViewController?.view else { return }
        let model = hostingController.model
        let profiles = prefs.savedExternalDeviceProfiles

        guard !profiles.isEmpty else {
            model.appAlert = .info(
                title: "No devices yet",
                message: "Add a device under Preferences > Devices, then use Transfer to Device."
            )
            return
        }

        let tracks = model.tracksForBatchScope(.currentAlbum)
        guard !tracks.isEmpty else {
            model.appAlert = .info(
                title: "Nothing to transfer",
                message: "Select an album or track first, or right-click an item and choose Transfer to Device."
            )
            return
        }

        if profiles.count == 1 {
            model.transferToDevice(profileID: profiles[0].id, tracks: tracks)
            return
        }

        let menu = NSMenu()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(pickDeviceForTransfer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: 24), in: contentView)
    }

    @objc private func pickDeviceForTransfer(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        let model = hostingController.model
        model.transferToDevice(profileID: profileID, tracks: model.tracksForBatchScope(.currentAlbum))
    }

    func cancelConversion() {
        hostingController.model.cancelConversion()
    }

    // MARK: - View / Playback delegations

    func setOLEDView(_ view: OLEDView) {
        hostingController.model.oledView = view
    }

    func currentOLEDView() -> OLEDView {
        hostingController.model.oledView
    }

    func togglePlayPause() {
        hostingController.model.togglePlayPause()
    }

    func importLibraryFile() {
        hostingController.model.importLibraryFile()
    }

    func exportLibraryFile() {
        hostingController.model.exportSelectedCrate()
    }

    func backUpLibrary() {
        hostingController.model.backUpLibrary()
    }

    func playNext() {
        hostingController.model.next()
    }

    func playPrevious() {
        hostingController.model.previous()
    }

    func rewind8s() {
        hostingController.model.rewind8s()
    }

    func forward8s() {
        hostingController.model.forward8s()
    }

    func adjustVolume(by delta: Double) {
        hostingController.model.setVolume(hostingController.model.playbackVolume + delta)
    }

    func toggleShuffle() {
        hostingController.model.toggleShuffle()
    }

    func cycleRepeatMode() {
        hostingController.model.cycleRepeatMode()
    }

    /// The user changed the Stream Engine preference (or yt-dlp path) via the menu.
    func streamEnginePreferenceChanged() {
        hostingController.model.streamEnginePreferenceChanged()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !didApplyRestoredFrame {
            didApplyRestoredFrame = true
            if prefs.savedWindowFrame != nil {
                applyWindowPlan(context: .clampToVisibleFrame, animated: false)
            } else {
                applyWindowPlan(context: .initialLaunch, animated: false)
            }
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyWindowPlan(context: .clampToVisibleFrame, animated: false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyWindowPlan(context: .clampToVisibleFrame, animated: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowWillClose(_ notification: Notification) {
        persistFrame()
    }

    private func persistFrame() {
        guard let window else { return }
        prefs.savedWindowFrame = window.frame
    }

    @objc private func handleAppearanceDidChange() {
        applyAppearancePreference()
    }

    private func applyAppearancePreference() {
        guard let window else { return }
        switch AppearanceMode.current {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark:  window.appearance = NSAppearance(named: .darkAqua)
        case .system: window.appearance = nil
        }
    }

    private func applyWindowPlan(context: WindowFramePlanningContext, animated: Bool) {
        guard let window else { return }

        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let baselineFrame: CGRect?
        if context == .clampToVisibleFrame, prefs.savedWindowFrame != nil, !window.isVisible {
            // First-launch restoration path: prefer the persisted frame over
            // the (uninitialized) current frame.
            baselineFrame = prefs.savedWindowFrame ?? window.frame
        } else {
            baselineFrame = window.frame
        }

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: baselineFrame,
            context: context
        )

        window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
        window.setFrame(NSRect(origin: plan.frame.origin, size: plan.frame.size), display: true, animate: animated)
    }
}
