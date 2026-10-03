import AppKit
import Combine
import CrateDiggerCore
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let hostingController = CarbonHostingController()

    /// The single shared view model — also used by the mini player.
    var model: LibraryViewModel { hostingController.model }
    private let prefs: PreferencesStore = .shared
    private var didApplyRestoredFrame = false
    /// The layout the window is currently sized for. Trails `model.playerLayout`
    /// by one runloop turn, which is what lets `switchLayout` save the
    /// outgoing frame into the outgoing layout's slot.
    private var layout: PlayerLayout = .full
    private var layoutObserver: AnyCancellable?
    /// The compact plan's size limits, kept here for `windowWillResize`.
    private var compactLimits: (minimum: CGSize, maximum: CGSize)?

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
        // Not movable by background: on macOS 27 a titled window claims every
        // drag over SwiftUI content for itself, rows' `.draggable` included, so
        // nothing in the browser could be dragged to a crate or playlist. The
        // titlebar strip still drags, and double-clicks per the system setting.
        window.isMovableByWindowBackground = false
        window.isRestorable = false

        super.init(window: window)

        // Activity lamp in the titlebar's trailing corner — the traffic
        // lights' opposite number. An accessory (not a content overlay) so it
        // sits in the real titlebar strip at the same height as the buttons.
        let ledAccessory = NSTitlebarAccessoryViewController()
        let ledView = NSHostingView(rootView: TitlebarStatusLED(model: hostingController.model))
        // Accessory layout uses the view's frame at add time — an unset frame
        // renders as zero-size (invisible LED).
        ledView.frame = NSRect(x: 0, y: 0, width: 34, height: 24)
        ledAccessory.view = ledView
        ledAccessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(ledAccessory)

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

        layout = hostingController.model.playerLayout
        layoutObserver = hostingController.model.$playerLayout
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.switchLayout(to: $0) }

        // A theme can change the header or footer height; the compact window
        // is exactly that tall, so it re-plans.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemesDidChange),
            name: PreferencesStore.themesDidChange,
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

    var hasNowPlayingTrack: Bool {
        hostingController.model.nowPlayingTrack != nil
    }

    func revealNowPlaying() {
        hostingController.model.revealNowPlaying()
    }

    func toggleFullScreenPlayer() {
        hostingController.model.fullScreenPlayerRequested = true
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

        let tracks = model.selectedAlbum?.tracks ?? []
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
        model.transferToDevice(profileID: profileID, tracks: model.selectedAlbum?.tracks ?? [])
    }

    func cancelConversion() {
        hostingController.model.cancelConversion()
    }

    // MARK: - View / Playback delegations

    /// ⌘F: put the browser somewhere the field can be seen and focus it.
    func focusSearch() {
        hostingController.model.requestSearchFocus()
    }

    func setOLEDView(_ view: OLEDView) {
        hostingController.model.oledView = view
    }

    func currentOLEDView() -> OLEDView {
        hostingController.model.oledView
    }

    func openThemeEditor() {
        hostingController.model.showingThemeEditor = true
    }

    func showWhatsNew() {
        hostingController.model.startWhatsNew()
    }

    func togglePlayPause() {
        hostingController.model.togglePlayPause()
    }

    func showWelcomeTour() {
        hostingController.model.startWelcomeTour()
    }

    func importSACDISO() {
        hostingController.model.beginSACDImport()
    }

    func setDSDOutputMode(_ mode: DSDOutputMode) {
        hostingController.model.dsdOutputMode = mode
    }

    func currentDSDOutputMode() -> DSDOutputMode {
        hostingController.model.dsdOutputMode
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
        hostingController.model.stepVolume(by: delta)
    }

    func toggleShuffle() {
        hostingController.model.toggleShuffle()
    }

    func cycleRepeatMode() {
        hostingController.model.cycleRepeatMode()
    }

    // MARK: - Queue + sleep (menu-bar entry points)

    func queueSelectionNext() {
        hostingController.model.playNext(hostingController.model.selectedTracksForCrateAdd())
    }

    func queueSelectionLast() {
        hostingController.model.playLast(hostingController.model.selectedTracksForCrateAdd())
    }

    func clearUpNext() {
        hostingController.model.clearUpNext()
    }

    func canQueueSelection() -> Bool {
        let model = hostingController.model
        return model.canQueueTracks && !model.selectedTracksForCrateAdd().isEmpty
    }

    func hasUpNext() -> Bool { hostingController.model.hasUpNext }

    func setSleepMode(_ mode: SleepMode) {
        hostingController.model.setSleepMode(mode)
    }

    func rateSelection(_ rating: Int) {
        hostingController.model.rateSelection(rating)
    }

    func currentSleepMode() -> SleepMode { hostingController.model.sleepMode }

    /// The user changed the Stream Engine preference (or yt-dlp path) via the menu.
    func streamEnginePreferenceChanged() {
        hostingController.model.streamEnginePreferenceChanged()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !didApplyRestoredFrame {
            didApplyRestoredFrame = true
            if layout == .compact {
                applyLayoutPlan(restoring: true, animated: false)
            } else if prefs.savedWindowFrame != nil {
                applyWindowPlan(context: .clampToVisibleFrame, animated: false)
            } else {
                applyWindowPlan(context: .initialLaunch, animated: false)
            }
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyLayoutPlan(restoring: false, animated: false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyLayoutPlan(restoring: false, animated: false)
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
        switch layout {
        case .full:    prefs.savedWindowFrame = window.frame
        case .compact: prefs.savedCompactWindowFrame = window.frame
        }
    }

    @objc private func handleAppearanceDidChange() {
        applyAppearancePreference()
    }

    private func applyAppearancePreference() {
        window?.appearance = AppearanceMode.current.nsAppearance
    }

    // MARK: - Compact player

    var isCompact: Bool { hostingController.model.isCompactPlayer }

    /// A full-screen window cannot fold into the compact player.
    var isInFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func toggleCompactPlayer() {
        showWindow(nil)
        hostingController.model.toggleCompactPlayer()
    }

    func expandToFull() {
        hostingController.model.expandToFull()
    }

    private func switchLayout(to newLayout: PlayerLayout) {
        guard newLayout != layout, let window else { return }
        persistFrame()          // into the outgoing layout's slot
        layout = newLayout
        applyLayoutPlan(restoring: true, animated: window.isVisible)
    }

    /// `restoring` reads the layout's saved frame (a switch, or launch);
    /// otherwise the current frame is re-clamped (screen or theme change).
    private func applyLayoutPlan(restoring: Bool, animated: Bool) {
        guard let window else { return }
        // The green button is full screen on a titled window, and a strip one
        // rack unit tall must not go full screen. Without full-screen support
        // the button zooms instead, and zoom while compact expands
        // (`windowShouldZoom`).
        if layout == .compact {
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
        } else {
            window.collectionBehavior.remove(.fullScreenNone)
        }
        switch layout {
        case .full:
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if restoring {
                let saved = prefs.savedWindowFrame
                applyWindowPlan(context: saved == nil ? .initialLaunch : .clampToVisibleFrame,
                                animated: animated, baseline: saved)
            } else {
                applyWindowPlan(context: .clampToVisibleFrame, animated: animated)
            }
        case .compact:
            let plan = WindowFramePlanner.compactPlan(
                visibleFrame: visibleFrame(for: window),
                savedFrame: restoring ? prefs.savedCompactWindowFrame : window.frame,
                anchor: window.frame,
                metrics: CompactDeckMetrics(geometry: activeGeometry())
            )
            // Minimum first: the full window's 1200 × 820 floor would refuse the shrink.
            window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
            window.maxSize = NSSize(width: plan.maximumSize.width, height: plan.maximumSize.height)
            compactLimits = (plan.minimumSize, plan.maximumSize)
            window.setFrame(plan.frame, display: true, animate: animated)
        }
    }

    private func visibleFrame(for window: NSWindow) -> CGRect {
        window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Resolved the way `CarbonRootView` resolves it.
    private func activeGeometry() -> CarbonGeometry {
        ThemeRegistry.shared.resolvedTheme(for: prefs.selectedThemeID)?.geometry ?? .standard
    }

    @objc private func handleThemesDidChange() {
        guard layout == .compact else { return }
        applyLayoutPlan(restoring: false, animated: window?.isVisible ?? false)
    }

    /// Holds the compact window to its fixed height and minimum width; the
    /// footer and display clip below it. Clamps to the limits the plan
    /// produced rather than `sender.minSize`/`maxSize`: by the time a live
    /// resize starts, AppKit has reset those to zero and unbounded (measured;
    /// the full window has the same problem on `main`, where it can be
    /// dragged down to 645 pt despite its 1200 pt minimum).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard layout == .compact, let limits = compactLimits else { return frameSize }
        return WindowFramePlanner.clampedSize(frameSize, minimum: limits.minimum, maximum: limits.maximum)
    }

    /// Zoom while compact means "the whole console", not a maximised strip.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard layout == .compact else { return true }
        expandToFull()
        return false
    }

    private func applyWindowPlan(context: WindowFramePlanningContext, animated: Bool, baseline override: CGRect? = nil) {
        guard let window else { return }
        let visibleFrame = visibleFrame(for: window)

        let baselineFrame: CGRect?
        if let override {
            baselineFrame = override
        } else if context == .clampToVisibleFrame, prefs.savedWindowFrame != nil, !window.isVisible {
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
