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
    /// One saved frame per layout; inert until the launch frame is restored.
    private var frameMemory = WindowFrameMemory(prefs: .shared)
    /// The layout the window is currently sized for. Trails `model.playerLayout`
    /// by one runloop turn, which is what lets `switchLayout` save the
    /// outgoing frame into the outgoing layout's slot.
    private var layout: PlayerLayout = .full
    private var layoutObserver: AnyCancellable?
    /// The current layout's size limits, kept here for `windowWillResize`.
    private var resizeLimits: (minimum: CGSize, maximum: CGSize)?
    /// Where an in-flight fold or unfold is taking the window. A frame saved
    /// while the window is still travelling must record where it is going,
    /// not a half-folded frame: folding back mid-flight saves the outgoing
    /// layout's frame, and that would otherwise be whatever size the
    /// animation had reached.
    private var frameInFlight: CGRect?
    /// Bumped per animated frame change, so a superseded animation's
    /// completion cannot clear the newer one's target.
    private var frameAnimationGeneration = 0
    /// The status LED in the full layout's titlebar trailing corner.
    private let ledAccessory = NSTitlebarAccessoryViewController()
    /// The same LED for the compact layout, over the art column (see
    /// `CompactDeckMetrics.statusLampCenterX`): the trailing corner would put
    /// it on the display's glass. Built on first use.
    private var compactLEDView: NSView?

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
        // It is a button too (it steps the NOW matrix's animation), so it is
        // hosted in a view that keeps its clicks from becoming window drags.
        // Compact moves it over the art column (`placeStatusLED`).
        let ledView = TitlebarButtonHostingView(rootView: TitlebarStatusLED(model: hostingController.model))
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
            // The Patch Bay's own lists, so a value picked there (96 kbps)
            // isn't a blank picker here. -1 is the sheet's "Source" tag.
            bitrateOptions: OutputFormat.bitrateOptions,
            sampleRateOptions: [-1, 44_100, 48_000, 88_200, 96_000]
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

    func setMatrixAnimation(_ kind: MatrixAnimationKind) {
        hostingController.model.matrixAnimation = kind
    }

    func currentMatrixAnimation() -> MatrixAnimationKind {
        hostingController.model.matrixAnimation
    }

    func enabledMatrixAnimations() -> Set<MatrixAnimationKind> {
        hostingController.model.enabledMatrixAnimations
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
            // Through the layout plan for both layouts: it passes the saved
            // frame as an explicit baseline. Re-deriving it from `isVisible`
            // here read the window as already visible (super.showWindow ran
            // first), so the full window never got its saved frame back.
            applyLayoutPlan(restoring: true, animated: false)
            frameMemory.arm()
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
        // A move while a fold is in flight (a drag that catches the window
        // mid-travel) must not record a half-folded frame; the animation's
        // completion records where it landed.
        guard frameInFlight == nil else { return }
        persistFrame()
    }

    func windowWillClose(_ notification: Notification) {
        persistFrame()
    }

    private func persistFrame() {
        guard let window else { return }
        frameMemory.record(restingFrame(of: window), for: layout)
    }

    /// The frame the window is at, or is on its way to while a fold is in
    /// flight. Anything that re-plans from "the current frame" reads this: a
    /// screen or backing change mid-fold (the unfolding window crossing onto
    /// another display) would otherwise clamp the half-folded frame and leave
    /// the window stuck at it.
    private func restingFrame(of window: NSWindow) -> CGRect {
        frameInFlight ?? window.frame
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
        // The menu item is disabled in full screen; the brand-row key sends
        // the same action unvalidated, so the refusal lives here too.
        guard !isInFullScreen else { NSSound.beep(); return }
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
        applyLayoutPlan(restoring: true, animated: window.isVisible, centringCompact: true)
    }

    /// `restoring` reads the layout's saved frame (a switch, or launch);
    /// otherwise the current frame is re-clamped (screen or theme change).
    /// `centringCompact` is a fold: the compact deck keeps its saved width
    /// but lands in the middle of the screen. At launch it stays where it
    /// was left.
    private func applyLayoutPlan(restoring: Bool, animated: Bool, centringCompact: Bool = false) {
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
                let saved = frameMemory.saved(for: .full)
                applyWindowPlan(context: saved == nil ? .initialLaunch : .clampToVisibleFrame,
                                animated: animated, baseline: saved)
            } else {
                applyWindowPlan(context: .clampToVisibleFrame, animated: animated)
            }
        case .compact:
            let plan = WindowFramePlanner.compactPlan(
                visibleFrame: visibleFrame(for: window),
                savedFrame: restoring ? frameMemory.saved(for: .compact) : restingFrame(of: window),
                fallbackWidth: restingFrame(of: window).width,
                centred: centringCompact,
                metrics: CompactDeckMetrics(geometry: activeGeometry())
            )
            // Minimum first: the full window's 1200 × 820 floor would refuse the shrink.
            window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
            window.maxSize = NSSize(width: plan.maximumSize.width, height: plan.maximumSize.height)
            resizeLimits = (plan.minimumSize, plan.maximumSize)
            setWindowFrame(plan.frame, animated: animated)
        }
        placeStatusLED()
    }

    /// Shows the status LED where the current layout has room for it: the
    /// titlebar's trailing corner in full, over the art column in compact.
    /// The compact lamp is a subview of the titlebar view itself (the traffic
    /// lights' superview), so it shares their strip, their drag exemption and
    /// their vertical centre exactly, whatever height this macOS gives the
    /// titlebar. Re-run on every layout plan, which covers theme changes.
    private func placeStatusLED() {
        guard let window else { return }
        let compact = layout == .compact
        // The accessory's own `isHidden` only collapses its slot (animated,
        // and not before the next titlebar layout); hiding the view is what
        // takes the lamp off the glass at once.
        ledAccessory.isHidden = compact
        ledAccessory.view.isHidden = compact
        guard compact else {
            compactLEDView?.isHidden = true
            return
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview else {
            // No titlebar to sit in: drop the lamp rather than float it on the glass.
            compactLEDView?.isHidden = true
            return
        }
        let side = CompactDeckMetrics.statusLampHitSide
        let led: NSView
        if let existing = compactLEDView {
            led = existing
        } else {
            led = TitlebarButtonHostingView(rootView: CompactTitlebarStatusLED(model: hostingController.model))
            compactLEDView = led
        }
        if led.superview !== titlebar {
            // AppKit can rebuild the titlebar view; follow it.
            led.removeFromSuperview()
            titlebar.addSubview(led)
        }
        let metrics = CompactDeckMetrics(geometry: activeGeometry())
        let centerX = titlebar.convert(NSPoint(x: metrics.statusLampCenterX, y: 0), from: nil).x
        led.frame = NSRect(x: centerX - side / 2, y: closeButton.frame.midY - side / 2, width: side, height: side)
        led.isHidden = false
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

    /// Holds the window to its layout's limits: the full window to its
    /// 1200 × 820 floor (less on a small screen), the compact window to its
    /// fixed height and minimum width. Below those the footer and display
    /// clip. Clamps to the limits the plan produced rather than
    /// `sender.minSize`/`maxSize`: by the time a live resize starts, AppKit
    /// has reset those to zero and unbounded (measured: without this the full
    /// window could be dragged down to 645 pt).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let limits = resizeLimits else { return frameSize }
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
            baselineFrame = restingFrame(of: window)
        }

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: baselineFrame,
            context: context
        )

        window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
        resizeLimits = (plan.minimumSize, CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        setWindowFrame(NSRect(origin: plan.frame.origin, size: plan.frame.size), animated: animated)
    }

    // The fold runs for `CarbonMotion.windowResize` in an NSAnimationContext.
    // AppKit's own `setFrame(_:display:animate:)` picks a time from the
    // distance (0.35 s for a full-to-compact fold) and holds the main thread
    // until it ends, so a click during the fold was lost.

    /// Moves the window to `frame`, travelling there when `animated` and the
    /// user has not asked for reduced motion. Never blocks: the animation
    /// runs through the window's animator, and input keeps flowing.
    private func setWindowFrame(_ frame: CGRect, animated: Bool) {
        guard let window else { return }
        guard animated, !CarbonMotion.prefersReducedMotion else {
            if frameInFlight != nil {
                // Something is already animating the frame; a plain setFrame
                // would be overwritten by its next tick. A zero-length
                // animation retargets it instead.
                frameInFlight = nil
                frameAnimationGeneration += 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    window.animator().setFrame(frame, display: true)
                }
                // A frame set through the animator never posts
                // `windowDidMove` (measured), so nothing else would record it.
                persistFrame()
            } else {
                window.setFrame(frame, display: true)
            }
            return
        }
        frameAnimationGeneration += 1
        let generation = frameAnimationGeneration
        frameInFlight = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = CarbonMotion.windowResize
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = false
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.frameAnimationGeneration == generation else { return }
            self.frameInFlight = nil
            // AppKit posts no `windowDidMove` for a frame animated through
            // the animator, not even on landing (measured); record it here.
            self.persistFrame()
        })
    }
}

/// `TitlebarStatusLED` without its trailing-corner padding: just the 18 pt
/// key, so the compact window can centre it on a point. Hosted
/// outside `CarbonRootView`'s environment, so it reads the appearance itself.
private struct CompactTitlebarStatusLED: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    let model: LibraryViewModel

    var body: some View {
        StatusLED()
            .environmentObject(model)
            .carbonThemed(mode: AppearanceMode(rawValue: appearanceModeRaw) ?? .system)
    }
}
