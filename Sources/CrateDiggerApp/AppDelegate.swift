import AppKit
import CrateDiggerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var mainWindowController: MainWindowController?
    private var aboutWindowController: AboutWindowController?
    private var guideWindowController: GuideWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var miniPlayerWindowController: MiniPlayerWindowController?
    private let prefs: PreferencesStore = .shared
    private var openRecentMenu: NSMenu?
    private var appearanceMenu: NSMenu?
    private var recentFolderURLs: [URL] = []
    private var spaceKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppVersion.isBetaExpired {
            presentBetaExpiredAndTerminate()
            return
        }

        // Sized HTTP cache so AsyncImage artwork (CAA thumbnails, previews) survives
        // scroll recycling + reopen instead of re-downloading each time.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)

        FontRegistrar.registerBundledFonts()

        migrateLegacyArtworkStore()

        buildMenu()

        let windowController = MainWindowController()
        self.mainWindowController = windowController
        windowController.showWindow(self)
        windowController.restoreLastSession()

        installSpaceKeyMonitor()
        installSnapshotHookIfRequested()

        // Touching the singleton starts Sparkle, including its once-a-day
        // background check. No-op in an unpackaged build.
        _ = SoftwareUpdater.shared

        NotificationCenter.default.addObserver(
            self, selector: #selector(showMiniPlayer(_:)),
            name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(showWelcomeTour(_:)),
            name: NSNotification.Name("CrateDiggerShowWelcomeTour"), object: nil)
    }

    /// Beta builds stop working after `AppVersion.betaExpiry`: show a notice
    /// (with a link to the latest build) and quit before the UI comes up.
    private func presentBetaExpiredAndTerminate() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This CrateDigger beta has expired"
        var info = "Beta \(AppVersion.marketing) (build \(AppVersion.build)) has reached its expiry date."
        if let expiry = AppVersion.betaExpiry {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            info = "Beta \(AppVersion.marketing) (build \(AppVersion.build)) expired on \(formatter.string(from: expiry))."
        }
        alert.informativeText = info + " Please download the latest build to keep using CrateDigger."
        alert.addButton(withTitle: "Get the Latest Build")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://cratedigger.mrbarkan.com") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = spaceKeyMonitor {
            NSEvent.removeMonitor(token)
            spaceKeyMonitor = nil
        }
    }

    /// Before 1.1.0 the artwork cache kept a full-resolution copy of every cover
    /// it ever saw, which grew to gigabytes on a large library. Squeeze that hoard
    /// down into the thumbnail cache and delete it — off the main thread, since a
    /// long-running library can have thousands of blobs to re-encode. Covers stay
    /// resolvable throughout: the migration only shrinks what's already there.
    private func migrateLegacyArtworkStore() {
        Task.detached(priority: .utility) {
            let store = ArtworkStore(directory: ArtworkStore.defaultDirectory)
            let reclaimed = store.migrateLegacyFullResolutionStore()
            guard reclaimed > 0 else { return }
            let megabytes = Double(reclaimed) / 1_000_000
            AppLog.library.notice("Migrated legacy artwork store; reclaimed \(megabytes, format: .fixed(precision: 1)) MB")
        }
    }

    /// Plain Space-as-menu-shortcut is unreliable in AppKit because focused
    /// controls and the responder chain swallow the keyDown first. We install
    /// a local monitor that fires Play/Pause when Space is pressed with no
    /// modifiers and no text editor is active, then consumes the event.
    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let modifiers = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return event }
            guard event.charactersIgnoringModifiers == " " else { return event }
            guard !Self.isTextEditingFirstResponder() else { return event }
            guard NSApp.keyWindow != nil else { return event }

            self.mainWindowController?.togglePlayPause()
            return nil
        }
    }

    private static func isTextEditingFirstResponder() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView, textView.isEditable {
            return true
        }
        // When a text field is focused the firstResponder is usually the
        // window's shared field editor (an NSTextView), but walk the superview
        // chain too for cases where the field itself owns focus.
        if let view = responder as? NSView {
            var node: NSView? = view
            while let n = node {
                if n is NSTextField || n is NSSearchField || n is NSComboBox {
                    return true
                }
                node = n.superview
            }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - File menu actions

    @objc private func openFolder(_ sender: Any?) {
        mainWindowController?.openFolder()
    }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        guard let index = sender.tag as Int?, recentFolderURLs.indices.contains(index) else { return }
        let url = recentFolderURLs[index]
        mainWindowController?.loadFolders([url])
    }

    @objc private func clearRecentMenu(_ sender: Any?) {
        prefs.savedLibraryFolderBookmarks = []
        rebuildRecentFoldersCache()
        rebuildOpenRecentMenu()
    }

    @objc private func revealSelectionInFinder(_ sender: Any?) {
        guard let url = mainWindowController?.currentSelectionURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func convertSelected(_ sender: Any?) {
        mainWindowController?.presentConversionSheet()
    }

    @objc private func transferToDevice(_ sender: Any?) {
        mainWindowController?.presentExternalDeviceTransferSheet()
    }

    @objc private func cancelConversion(_ sender: Any?) {
        mainWindowController?.cancelConversion()
    }

    // MARK: - View menu

    @objc private func selectOLEDView(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let view = OLEDView(rawValue: raw) else { return }
        mainWindowController?.setOLEDView(view)
    }

    // MARK: - Playback menu

    @objc private func togglePlayPause(_ sender: Any?) {
        mainWindowController?.togglePlayPause()
    }

    @objc private func goToCurrentSong(_ sender: Any?) {
        mainWindowController?.revealNowPlaying()
    }

    @objc private func playNext(_ sender: Any?) {
        mainWindowController?.playNext()
    }

    @objc private func playPrevious(_ sender: Any?) {
        mainWindowController?.playPrevious()
    }

    @objc private func rewind8s(_ sender: Any?) {
        mainWindowController?.rewind8s()
    }

    @objc private func forward8s(_ sender: Any?) {
        mainWindowController?.forward8s()
    }

    @objc private func volumeUp(_ sender: Any?) {
        mainWindowController?.adjustVolume(by: 0.05)
    }

    @objc private func volumeDown(_ sender: Any?) {
        mainWindowController?.adjustVolume(by: -0.05)
    }

    @objc private func toggleShuffle(_ sender: Any?) {
        mainWindowController?.toggleShuffle()
    }

    /// The sleep options the menu offers, in order.
    static let sleepMenuModes: [SleepMode] =
        [.off] + SleepMode.presetMinutes.map { .after(minutes: $0) } + [.endOfTrack, .endOfQueue]

    /// `representedObject` has to be a plain value, so modes travel as a string.
    static func sleepTag(for mode: SleepMode) -> String {
        switch mode {
        case .off:                return "off"
        case .after(let minutes): return "after:\(minutes)"
        case .endOfTrack:         return "endOfTrack"
        case .endOfQueue:         return "endOfQueue"
        }
    }

    static func sleepMode(fromTag tag: String) -> SleepMode? {
        switch tag {
        case "off":         return .off
        case "endOfTrack":  return .endOfTrack
        case "endOfQueue":  return .endOfQueue
        default:
            guard tag.hasPrefix("after:"), let minutes = Int(tag.dropFirst(6)) else { return nil }
            return .after(minutes: minutes)
        }
    }

    @objc private func setSleepMode(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.representedObject as? String,
              let mode = Self.sleepMode(fromTag: tag) else { return }
        mainWindowController?.setSleepMode(mode)
    }

    @objc private func setRating(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        mainWindowController?.rateSelection(item.tag)
    }

    @objc private func queuePlayNext(_ sender: Any?) {
        mainWindowController?.queueSelectionNext()
    }

    @objc private func queuePlayLast(_ sender: Any?) {
        mainWindowController?.queueSelectionLast()
    }

    @objc private func clearUpNext(_ sender: Any?) {
        mainWindowController?.clearUpNext()
    }

    @objc private func cycleRepeatMode(_ sender: Any?) {
        mainWindowController?.cycleRepeatMode()
    }

    // MARK: - Stream Engine menu

    @objc private func setDSDOutputMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DSDOutputMode(rawValue: raw) else { return }
        mainWindowController?.setDSDOutputMode(mode)
    }

    @objc private func setStreamEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        prefs.streamEngine = raw
        mainWindowController?.streamEnginePreferenceChanged()
        // The checkmark is set in validateMenuItem when the menu next opens.
    }

    @objc private func setYtDlpPath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose the yt-dlp binary"
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.customYtDlpPath = url.path
        mainWindowController?.streamEnginePreferenceChanged()
    }

    @objc private func checkYouTubeStreaming(_ sender: Any?) {
        MainActor.assumeIsolated {
            mainWindowController?.model.checkYouTubeStreaming()
        }
    }

    // MARK: - App menu actions

    // MARK: - Library Files

    @objc private func importSACDISO(_ sender: Any?) {
        mainWindowController?.importSACDISO()
    }

    @objc private func importLibraryFile(_ sender: Any?) {
        mainWindowController?.importLibraryFile()
    }

    @objc private func exportLibraryFile(_ sender: Any?) {
        mainWindowController?.exportLibraryFile()
    }

    @objc private func backUpLibrary(_ sender: Any?) {
        mainWindowController?.backUpLibrary()
    }

    // MARK: - Mini Player

    /// Open the floating mini player and tuck the full app away (alternate modes).
    @objc private func showMiniPlayer(_ sender: Any?) {
        guard let model = mainWindowController?.model else { return }
        if miniPlayerWindowController == nil {
            miniPlayerWindowController = MiniPlayerWindowController(model: model, onExpand: { [weak self] in
                self?.exitMiniPlayer()
            })
        }
        miniPlayerWindowController?.showWindow(nil)
        miniPlayerWindowController?.window?.orderFrontRegardless()
        mainWindowController?.window?.orderOut(nil)
    }

    /// Return from the mini player to the full app (keeps the mini's position).
    private func exitMiniPlayer() {
        miniPlayerWindowController?.window?.orderOut(nil)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated {
            SoftwareUpdater.shared.checkForUpdates()
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(self)
        aboutWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWelcomeTour(_ sender: Any?) {
        mainWindowController?.showWelcomeTour()
        mainWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWhatsNew(_ sender: Any?) {
        mainWindowController?.showWhatsNew()
        mainWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showGuide(_ sender: Any?) {
        if guideWindowController == nil {
            guideWindowController = GuideWindowController()
        }
        guideWindowController?.showWindow(self)
        guideWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(self)
        preferencesWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHelpPage(_ sender: Any?) {
        if let url = URL(string: "https://cratedigger.mrbarkan.com") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Dev-only self-snapshot: with CRATEDIGGER_SNAPSHOT_PATH set, render the
    /// main window (its own view tree — no screen-recording permission needed)
    /// to a PNG a few seconds after launch, then again 4 s later. Optional
    /// CRATEDIGGER_OLED=<rawValue> preselects an OLED view first. Inert
    /// without the env var; used for autonomous UI verification.
    private func installSnapshotHookIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CRATEDIGGER_SNAPSHOT_PATH"] else { return }
        // Just before the final snap — starting playback flips the OLED to NOW
        // asynchronously, so an early set gets overridden.
        if let raw = env["CRATEDIGGER_OLED"], let view = OLEDView(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.mainWindowController?.model.oledView = view
            }
        }
        // The theme picker replaces the inspector, and nothing else can drive it
        // without clicking the header (which needs accessibility permission).
        if env["CRATEDIGGER_THEME_PICKER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.mainWindowController?.model.showingThemePicker = true
            }
        }
        // Value is an optional token filter ("fonts", "corner"), so a capture
        // can bring one section of the editor into view.
        if let raw = env["CRATEDIGGER_THEME_EDITOR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let model = self?.mainWindowController?.model else { return }
                if raw != "1" { model.themeEditorInitialFilter = raw }
                model.showingThemeEditor = true
            }
        }
        if env["CRATEDIGGER_WHATS_NEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.mainWindowController?.model.startWhatsNew()
            }
        }
        if env["CRATEDIGGER_AUTOPLAY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let model = self?.mainWindowController?.model else { return }
                model.playbackVolume = 0.8   // meters scale by volume; 0 reads as silence
                if let first = model.index.allTracks.first { model.playTrack(id: first.track.id) }
            }
        }
        // Dev-only: land on a source the UI can't otherwise be pointed at from
        // the command line, so a snapshot can show it. "playlist:<name>" only —
        // everything else is reachable by launching and clicking.
        if let raw = env["CRATEDIGGER_SOURCE"], raw.hasPrefix("playlist:") {
            let name = String(raw.dropFirst("playlist:".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.mainWindowController?.model.selectSource(.playlist(name: name))
            }
        }
        // A device route otherwise needs an iPod physically plugged in, which put
        // the routed CNVRT cockpit out of reach of a snapshot. This makes the same
        // in-memory hand-off the browser's "Send to device" makes — nothing is
        // written until the key is pressed.
        if env["CRATEDIGGER_DEVICE_ROUTE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { [weak self] in
                guard let model = self?.mainWindowController?.model,
                      let profile = PreferencesStore.shared.savedExternalDeviceProfiles.first
                else { return }
                model.pendingDeviceConversion = PendingDeviceConversion(
                    profileID: profile.id,
                    deviceName: profile.name,
                    destinationRoot: URL(fileURLWithPath: profile.rootDisplayPath ?? "/Volumes/\(profile.name)"),
                    tracks: Array(Self.previewTracks(from: model).prefix(11))
                )
                model.oledView = .conversion
            }
        }
        // The device strip and the album dots need a queue, which needs an iPod
        // on the other end of a USB cable. This fakes one in memory — nothing is
        // written, so the real queue is untouched.
        // "stage" runs the real queueing path (and writes a real queue file);
        // anything else fakes one in memory and writes nothing.
        if let raw = env["CRATEDIGGER_SYNC_QUEUE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let model = self?.mainWindowController?.model,
                      let profile = PreferencesStore.shared.savedExternalDeviceProfiles.first
                else { return }
                // One whole album, so an album row carries the dot.
                let album = model.index.artists.flatMap(\.albums).first
                let tracks = album?.tracks ?? Array(Self.previewTracks(from: model).prefix(11))
                if raw == "stage" {
                    model.stageForSync(profile: profile, tracks: tracks)
                    model.appAlert = nil   // the confirmation would cover the shot
                } else {
                    model.installPreviewSyncQueue(profileID: profile.id, tracks: tracks)
                }
            }
        }
        // The artwork navigator only opens from a click in the browser, so its two
        // presentations were unverifiable from the command line. "float" pops the
        // floating panel, anything else the full-screen viewer.
        if let raw = env["CRATEDIGGER_ARTWORK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let model = self?.mainWindowController?.model,
                      let album = model.index.artists.flatMap(\.albums)
                        .first(where: { $0.tracks.contains { $0.track.artworkHash != nil } })
                        ?? model.index.artists.first?.albums.first
                else { return }
                guard raw == "float",
                      let resolved = ThemeRegistry.shared.resolvedTheme(for: PreferencesStore.shared.selectedThemeID)
                else { return model.artworkViewerAlbum = album }
                ArtworkViewerPresenter.float(album: album, theme: resolved.theme, model: model, index: 0)
            }
        }
        if env["CRATEDIGGER_CHECK_STREAM"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.mainWindowController?.model.checkYouTubeStreaming()
            }
        }
        func write(_ window: NSWindow, to dest: URL, fail: (String) -> Void) {
            guard let frameView = window.contentView?.superview ?? window.contentView else { return fail("no frame view") }
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return fail("no rep for \(frameView.bounds)") }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return fail("no png data") }
            do { try png.write(to: dest) } catch { fail("write: \(error)") }
        }

        func snap(_ suffix: String) {
            let url = URL(fileURLWithPath: path)
            func fail(_ why: String) {
                try? why.write(to: url.appendingPathExtension("err.txt"), atomically: true, encoding: .utf8)
            }
            guard let window = self.mainWindowController?.window else { return fail("no window") }
            let dest = suffix.isEmpty ? url : url.deletingPathExtension().appendingPathExtension("\(suffix).png")
            write(window, to: dest, fail: fail)

            // Tool panels and sheets are separate NSWindows, so the main-window
            // capture never contained them and every panel change shipped
            // unseen. Each gets its own file, named after its title — sheets
            // have none, so they're numbered instead.
            var untitled = 0
            for panel in NSApp.windows where panel !== window && panel.isVisible {
                let slug: String
                if panel.title.isEmpty {
                    untitled += 1
                    slug = "sheet\(untitled)"
                } else {
                    slug = panel.title.lowercased().replacingOccurrences(of: " ", with: "-")
                }
                write(panel, to: url.deletingPathExtension()
                    .appendingPathExtension("\(slug)\(suffix.isEmpty ? "" : ".\(suffix)").png"), fail: fail)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { snap("") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { snap("late") }
        if env["CRATEDIGGER_SHOT_LIST"] != nil {
            runMarketingShotList(into: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        if let dumpPath = env["CRATEDIGGER_DEBUG_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { [weak self] in
                guard let model = self?.mainWindowController?.model else { return }
                let s = model.currentPlaybackSpectrum().map { String(format: "%.3f", $0) }.joined(separator: " ")
                let l = model.currentPlaybackLevels()
                let line = "state=\(model.playbackState) oled=\(model.oledView) levels=(\(l.left), \(l.right)) spectrum=[\(s)]"
                try? line.write(toFile: dumpPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The album on screen if there is one, else whatever is loaded — so the
    /// routed-cockpit snapshot has a queue in it either way.
    @MainActor
    private static func previewTracks(from model: LibraryViewModel) -> [LoadedTrack] {
        let album = model.selectedAlbum?.tracks ?? []
        return album.isEmpty ? model.index.allTracks : album
    }

    /// Dev-only: walk the app through the states the website shows and write one
    /// PNG per state into `folder`, named exactly like `website/assets`. Driven by
    /// `CRATEDIGGER_SHOT_LIST=1` alongside `CRATEDIGGER_SNAPSHOT_PATH`.
    ///
    /// It has to run in the *real* app (Xcode ⌘R or the packaged build) because a
    /// bare `.build` binary can't resolve the security-scoped bookmarks for your
    /// crate folders, and a screenshot of an empty library is worth nothing. The
    /// long gaps are deliberate: scanning, artwork resolution and the OLED
    /// transitions all settle asynchronously.
    private func runMarketingShotList(into folder: URL) {
        // (seconds after launch, file name, state to set up). The gaps are wide
        // because scanning, artwork and AVPlayer all settle asynchronously — a
        // hero shot taken too early just says NOTHING PLAYING.
        let shots: [(TimeInterval, String, @MainActor (LibraryViewModel) -> Void)] = [
            (8, "", { model in
                Self.setAppearance(.dark)
                model.selectSource(.localAll)
                model.oledView = .nowPlaying
                model.playbackVolume = 0.8
            }),
            (12, "", { model in
                // Has to be a track of the *selected* album: playTrack looks the
                // id up in `currentAlbumQueue()` and silently returns otherwise.
                if let first = model.selectedAlbum?.tracks.first { model.playTrack(id: first.track.id) }
            }),
            (18, "screenshot_dark", { _ in }),
            (21, "screenshot_light", { _ in Self.setAppearance(.light) }),
            (25, "screenshot_conversion", { model in model.oledView = .conversion }),
            (29, "screenshot_crates", { model in
                model.oledView = .nowPlaying
                model.selectSource(.prepCrate)
            }),
            (33, "screenshot_radio", { model in
                // Whichever category actually has stations — an empty one shoots
                // the "No streams yet" placeholder.
                let category = model.streamCategories.first ?? .youtubeRecords
                model.selectSource(.radio(category: category))
            }),
            (37, "screenshot_artwork", { model in
                model.selectSource(.localAll)
                model.showArtworkGallery = true   // a wall of covers reads better than one
                model.inspectorTab = .art
            }),
            (41, "", { model in model.showArtworkGallery = false })   // leave the app as we found it
        ]

        for (at, name, setUp) in shots {
            // Set the state up, then let it settle for a beat before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                MainActor.assumeIsolated {
                    guard let model = self?.mainWindowController?.model else { return }
                    setUp(model)
                }
            }
            guard !name.isEmpty else { continue }   // setup-only step
            DispatchQueue.main.asyncAfter(deadline: .now() + at + 2.5) { [weak self] in
                self?.captureWindow(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        NSLog("[shot list] capturing 6 screenshots into \(folder.path); leave the app alone for ~45s")
    }

    private static func setAppearance(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
    }

    /// Renders the main window's own view tree to a PNG — no screen-recording
    /// permission, and nothing else on screen can get into the frame.
    @discardableResult
    private func captureWindow(to url: URL) -> Bool {
        guard let window = mainWindowController?.window,
              let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            NSLog("[shot list] wrote \(url.lastPathComponent)")
            return true
        } catch {
            NSLog("[shot list] failed to write \(url.lastPathComponent): \(error)")
            return false
        }
    }

    @objc private func sendFeedback(_ sender: Any?) {
        if let url = URL(string: "mailto:opa@mrbarkan.com?subject=CrateDigger%20Feedback") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSupportPage(_ sender: Any?) {
        if let url = URL(string: "https://www.patreon.com/mrbarkan") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func setAppearanceMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw)
        else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
        // The selected theme is deliberately left alone: appearance is now a
        // property *of* the theme you're using — a theme carrying both looks
        // follows this, and one that doesn't keeps its own. Matches the THEME
        // picker in the inspector.
        // The checkmark is set in validateMenuItem when the menu next opens.
    }

    // MARK: - Appearance & Themes menu

    /// Appearance submenu = the three appearances, the installed themes, then
    /// the folder actions. Rebuilt via `menuNeedsUpdate` each time it opens.
    private func rebuildAppearanceMenu() {
        guard let menu = appearanceMenu else { return }
        menu.removeAllItems()
        for mode in AppearanceMode.allCases {
            let item = makeItem(title: mode.menuTitle, action: #selector(setAppearanceMode(_:)))
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        // Menus only ever touch us on the main thread; ThemeRegistry is @MainActor.
        let manifests = MainActor.assumeIsolated { ThemeRegistry.shared.manifests }
        if !manifests.isEmpty {
            menu.addItem(.separator())
            for manifest in manifests {
                let item = makeItem(title: manifest.definition.name, action: #selector(selectTheme(_:)))
                item.representedObject = manifest.id
                item.state = (manifest.id == prefs.selectedThemeID) ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Theme Editor…", action: #selector(openThemeEditor(_:))))
        menu.addItem(makeItem(title: "Refresh Themes", action: #selector(refreshThemes(_:))))
        menu.addItem(makeItem(title: "Show Themes Folder…", action: #selector(showThemesFolder(_:))))
    }

    @objc private func openThemeEditor(_ sender: Any?) {
        mainWindowController?.openThemeEditor()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === appearanceMenu { rebuildAppearanceMenu() }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.selectedThemeID = id
    }

    @objc private func refreshThemes(_ sender: Any?) {
        MainActor.assumeIsolated { ThemeRegistry.shared.refresh() }
    }

    @objc private func showThemesFolder(_ sender: Any?) {
        guard let url = MainActor.assumeIsolated({ ThemeRegistry.shared.userThemesDirectory }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setSleepMode(_:)):
            if let tag = menuItem.representedObject as? String,
               let mode = Self.sleepMode(fromTag: tag) {
                menuItem.state = (mainWindowController?.currentSleepMode() == mode) ? .on : .off
            }
            return true
        case #selector(queuePlayNext(_:)), #selector(queuePlayLast(_:)):
            return mainWindowController?.canQueueSelection() == true
        case #selector(setRating(_:)):
            return !(mainWindowController?.model.resolvedSelectionTracks().isEmpty ?? true)
        case #selector(clearUpNext(_:)):
            return mainWindowController?.hasUpNext() == true
        case #selector(setAppearanceMode(_:)):
            menuItem.state = (menuItem.representedObject as? String == AppearanceMode.current.rawValue) ? .on : .off
            return true
        case #selector(selectOLEDView(_:)):
            if let raw = menuItem.representedObject as? String,
               let view = OLEDView(rawValue: raw),
               let current = mainWindowController?.currentOLEDView() {
                menuItem.state = (view == current) ? .on : .off
            }
            return true
        case #selector(setStreamEngine(_:)):
            menuItem.state = (menuItem.representedObject as? String == prefs.streamEngine) ? .on : .off
            return true
        case #selector(setDSDOutputMode(_:)):
            let current = mainWindowController?.currentDSDOutputMode() ?? .auto
            menuItem.state = (menuItem.representedObject as? String == current.rawValue) ? .on : .off
            return true
        case #selector(revealSelectionInFinder(_:)),
             #selector(convertSelected(_:)),
             #selector(transferToDevice(_:)):
            return (mainWindowController?.currentSelectionURL() != nil)
                && !(mainWindowController?.isConversionRunning ?? false)
        case #selector(cancelConversion(_:)):
            return mainWindowController?.isConversionRunning ?? false
        case #selector(checkForUpdates(_:)):
            // Off in a development build, which has no update feed — see
            // `SoftwareUpdater`.
            return MainActor.assumeIsolated { SoftwareUpdater.shared.canCheckForUpdates }
        case #selector(togglePlayPause(_:)),
             #selector(playNext(_:)),
             #selector(playPrevious(_:)),
             #selector(rewind8s(_:)),
             #selector(forward8s(_:)),
             #selector(volumeUp(_:)),
             #selector(volumeDown(_:)),
             #selector(toggleShuffle(_:)),
             #selector(cycleRepeatMode(_:)):
            return mainWindowController?.hasLoadedTracks ?? false
        case #selector(goToCurrentSong(_:)):
            return mainWindowController?.hasNowPlayingTrack ?? false
        case #selector(openRecentItem(_:)):
            return menuItem.tag < recentFolderURLs.count
        default:
            return true
        }
    }

    private func rebuildRecentFoldersCache() {
        recentFolderURLs = []
        for data in prefs.savedLibraryFolderBookmarks {
            if let resolved = PreferencesStore.resolveBookmark(data) {
                recentFolderURLs.append(resolved.url)
            }
        }
    }

    private func rebuildOpenRecentMenu() {
        guard let menu = openRecentMenu else { return }
        menu.removeAllItems()
        if recentFolderURLs.isEmpty {
            let empty = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, url) in recentFolderURLs.enumerated() {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecentItem(_:)),
                    keyEquivalent: ""
                )
                item.tag = index
                item.target = self
                item.toolTip = url.path
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clear = NSMenuItem(title: "Clear Recent", action: #selector(clearRecentMenu(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // MARK: App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(makeItem(title: "About CrateDigger", action: #selector(showAbout(_:))))
        appMenu.addItem(makeItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem(title: "Preferences…", action: #selector(showPreferences(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem(title: "Hide CrateDigger", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        let hideOthers = makeItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(makeItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem(title: "Quit CrateDigger", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        appMenuItem.submenu = appMenu

        // MARK: File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(makeItem(title: "Dig Crate…", action: #selector(openFolder(_:)), key: "o"))
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentSubmenu = NSMenu(title: "Open Recent")
        openRecentItem.submenu = openRecentSubmenu
        self.openRecentMenu = openRecentSubmenu
        rebuildRecentFoldersCache()
        rebuildOpenRecentMenu()
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeItem(title: "Import SACD ISO…", action: #selector(importSACDISO(_:))))
        fileMenu.addItem(.separator())

        let libraryMenu = NSMenu(title: "Library")
        libraryMenu.addItem(makeItem(title: "Import Library File…", action: #selector(importLibraryFile(_:))))
        libraryMenu.addItem(makeItem(title: "Export Library File…", action: #selector(exportLibraryFile(_:))))
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(makeItem(title: "Back Up Library…", action: #selector(backUpLibrary(_:))))
        let libraryItem = NSMenuItem(title: "Library", action: nil, keyEquivalent: "")
        libraryItem.submenu = libraryMenu
        fileMenu.addItem(libraryItem)
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeItem(title: "Reveal Selection in Finder", action: #selector(revealSelectionInFinder(_:)), key: "r"))
        fileMenu.addItem(.separator())
        let convertItem = makeItem(title: "Convert Selected…", action: #selector(convertSelected(_:)), key: "c")
        convertItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(convertItem)
        let transferItem = makeItem(title: "Transfer to Device…", action: #selector(transferToDevice(_:)), key: "t")
        transferItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(transferItem)
        fileMenu.addItem(makeItem(title: "Cancel Conversion", action: #selector(cancelConversion(_:)), key: "."))
        fileMenuItem.submenu = fileMenu

        // MARK: Edit menu (Cocoa responder-chain items; target nil)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderItem(title: "Cut", action: NSSelectorFromString("cut:"), key: "x"))
        editMenu.addItem(responderItem(title: "Copy", action: NSSelectorFromString("copy:"), key: "c"))
        editMenu.addItem(responderItem(title: "Paste", action: NSSelectorFromString("paste:"), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu

        // MARK: View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        // Match the order shown in the OLED view switcher.
        let displayedViews: [(OLEDView, String)] = [
            (.nowPlaying, "1"),
            (.conversion, "2"),
            (.scan, "3"),
            (.devices, "4")
        ]
        for (view, key) in displayedViews {
            let item = makeItem(title: "\(view.label) Display", action: #selector(selectOLEDView(_:)), key: key)
            item.representedObject = view.rawValue
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        // ⌘L is what Music.app binds "Go to Current Song" to — muscle memory for free.
        viewMenu.addItem(makeItem(title: "Go to Current Song", action: #selector(goToCurrentSong(_:)), key: "l"))
        viewMenuItem.submenu = viewMenu

        // MARK: Playback menu
        let playbackMenuItem = NSMenuItem()
        mainMenu.addItem(playbackMenuItem)
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenu.addItem(makeItem(title: "Play / Pause", action: #selector(togglePlayPause(_:)), key: " "))
        let nextItem = makeItem(title: "Next", action: #selector(playNext(_:)), key: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        nextItem.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(nextItem)
        let prevItem = makeItem(title: "Previous", action: #selector(playPrevious(_:)), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prevItem.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(prevItem)
        let fwd8 = makeItem(title: "Forward 8 s", action: #selector(forward8s(_:)), key: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        fwd8.keyEquivalentModifierMask = [.command, .option]
        playbackMenu.addItem(fwd8)
        let rew8 = makeItem(title: "Rewind 8 s", action: #selector(rewind8s(_:)), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        rew8.keyEquivalentModifierMask = [.command, .option]
        playbackMenu.addItem(rew8)
        playbackMenu.addItem(.separator())
        let volUp = makeItem(title: "Volume Up", action: #selector(volumeUp(_:)), key: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        volUp.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(volUp)
        let volDown = makeItem(title: "Volume Down", action: #selector(volumeDown(_:)), key: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        volDown.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(volDown)
        playbackMenu.addItem(.separator())
        let shuffleItem = makeItem(title: "Toggle Shuffle", action: #selector(toggleShuffle(_:)), key: "s")
        shuffleItem.keyEquivalentModifierMask = [.command, .option]
        playbackMenu.addItem(shuffleItem)
        playbackMenu.addItem(.separator())
        let ratingMenuItem = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu(title: "Rating")
        let clearItem = makeItem(title: "Clear Rating", action: #selector(setRating(_:)), key: "0")
        clearItem.keyEquivalentModifierMask = [.command, .option]
        ratingMenu.addItem(clearItem)
        for stars in 1...5 {
            let item = makeItem(
                title: stars == 1 ? "1 Star" : "\(stars) Stars",
                action: #selector(setRating(_:)),
                key: String(stars)
            )
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = stars
            ratingMenu.addItem(item)
        }
        ratingMenuItem.submenu = ratingMenu
        playbackMenu.addItem(ratingMenuItem)
        let repeatItem = makeItem(title: "Cycle Repeat Mode", action: #selector(cycleRepeatMode(_:)), key: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .option]
        playbackMenu.addItem(repeatItem)
        playbackMenu.addItem(.separator())

        // Queue: acts on the browser selection, same as the context menu.
        let playNextItem = makeItem(title: "Play Next", action: #selector(queuePlayNext(_:)), key: "n")
        playNextItem.keyEquivalentModifierMask = [.command, .control]
        playbackMenu.addItem(playNextItem)
        let playLastItem = makeItem(title: "Play Last", action: #selector(queuePlayLast(_:)), key: "l")
        playLastItem.keyEquivalentModifierMask = [.command, .control]
        playbackMenu.addItem(playLastItem)
        playbackMenu.addItem(makeItem(title: "Clear Up Next", action: #selector(clearUpNext(_:))))
        playbackMenu.addItem(.separator())

        // Sleep timer. Fixed intervals plus the two playback boundaries.
        let sleepMenuItem = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
        let sleepMenu = NSMenu(title: "Sleep Timer")
        for mode in Self.sleepMenuModes {
            let item = makeItem(title: mode.menuTitle, action: #selector(setSleepMode(_:)))
            item.representedObject = Self.sleepTag(for: mode)
            sleepMenu.addItem(item)
            if case .off = mode { sleepMenu.addItem(.separator()) }
        }
        sleepMenuItem.submenu = sleepMenu
        playbackMenu.addItem(sleepMenuItem)
        playbackMenu.addItem(.separator())

        // DSD output picker: bit-perfect DoP to a capable DAC, or PCM decode.
        let dsdMenuItem = NSMenuItem(title: "DSD Output", action: nil, keyEquivalent: "")
        let dsdMenu = NSMenu(title: "DSD Output")
        let dsdModes: [(String, DSDOutputMode)] = [
            ("Auto (Bit-Perfect if the DAC can)", .auto),
            ("PCM (Compatible)", .pcm),
            ("Native (Bit-Perfect DoP)", .native)
        ]
        for (title, mode) in dsdModes {
            let item = makeItem(title: title, action: #selector(setDSDOutputMode(_:)))
            item.representedObject = mode.rawValue
            dsdMenu.addItem(item)
        }
        dsdMenuItem.submenu = dsdMenu
        playbackMenu.addItem(dsdMenuItem)
        playbackMenu.addItem(.separator())

        // Radio / Streams engine picker (Auto / Native / WebView) + yt-dlp path.
        let engineMenuItem = NSMenuItem(title: "Stream Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu(title: "Stream Engine")
        let engines: [(String, String)] = [
            ("Auto (yt-dlp if available)", "auto"),
            ("Native — yt-dlp", "native"),
            ("WebView — embedded", "webview")
        ]
        for (title, raw) in engines {
            let item = makeItem(title: title, action: #selector(setStreamEngine(_:)))
            item.representedObject = raw
            item.state = (prefs.streamEngine == raw) ? .on : .off
            engineMenu.addItem(item)
        }
        engineMenu.addItem(.separator())
        engineMenu.addItem(makeItem(title: "Set yt-dlp Path…", action: #selector(setYtDlpPath(_:))))
        engineMenu.addItem(makeItem(title: "Check YouTube Streaming…", action: #selector(checkYouTubeStreaming(_:))))
        engineMenuItem.submenu = engineMenu
        playbackMenu.addItem(engineMenuItem)

        playbackMenuItem.submenu = playbackMenu

        // MARK: Appearance menu
        // Top level, right after Playback, rather than buried in the app menu:
        // skins are a headline feature now that they're authorable in-app, and
        // nobody looks under CrateDigger ▸ for them.
        let appearanceMenuItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        mainMenu.addItem(appearanceMenuItem)
        let appearanceSubmenu = NSMenu(title: "Appearance")
        appearanceSubmenu.delegate = self   // rebuilt on open so dropped-in themes appear
        self.appearanceMenu = appearanceSubmenu
        rebuildAppearanceMenu()
        appearanceMenuItem.submenu = appearanceSubmenu

        // MARK: Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(responderItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), key: "m"))
        windowMenu.addItem(responderItem(title: "Zoom", action: #selector(NSWindow.zoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeItem(title: "Mini Player", action: #selector(showMiniPlayer(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // MARK: Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(makeItem(title: "CrateDigger Guide", action: #selector(showGuide(_:))))
        helpMenu.addItem(makeItem(title: "Welcome Tour", action: #selector(showWelcomeTour(_:))))
        helpMenu.addItem(makeItem(title: "What's New", action: #selector(showWhatsNew(_:))))
        helpMenu.addItem(.separator())
        helpMenu.addItem(makeItem(title: "CrateDigger Help", action: #selector(openHelpPage(_:)), key: "?"))
        helpMenu.addItem(makeItem(title: "Send Feedback…", action: #selector(sendFeedback(_:))))
        helpMenu.addItem(.separator())
        helpMenu.addItem(makeItem(title: "Support CrateDigger…", action: #selector(openSupportPage(_:))))
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(
        title: String,
        action: Selector,
        key: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    /// Menu item that travels the responder chain (target = nil).
    private func responderItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        // NSMenuItem has no NSNull-compatible "explicit nil" affordance, so
        // construct without our helper to keep target nil.
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}
