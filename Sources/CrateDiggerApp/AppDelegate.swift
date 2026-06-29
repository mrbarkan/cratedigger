import AppKit
import CrateDiggerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindowController: MainWindowController?
    private var aboutWindowController: AboutWindowController?
    private var guideWindowController: GuideWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var miniPlayerWindowController: MiniPlayerWindowController?
    private let prefs: PreferencesStore = .shared
    private var openRecentMenu: NSMenu?
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

        buildMenu()

        let windowController = MainWindowController()
        self.mainWindowController = windowController
        windowController.showWindow(self)
        windowController.restoreLastSession()

        installSpaceKeyMonitor()

        NotificationCenter.default.addObserver(
            self, selector: #selector(showMiniPlayer(_:)),
            name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
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
           let url = URL(string: "https://smash.mrbarkan.com") {
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

    @objc private func cycleRepeatMode(_ sender: Any?) {
        mainWindowController?.cycleRepeatMode()
    }

    // MARK: - Stream Engine menu

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

    // MARK: - App menu actions

    // MARK: - Library Files

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

    @objc private func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(self)
        aboutWindowController?.window?.makeKeyAndOrderFront(self)
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
        if let url = URL(string: "https://smash.mrbarkan.com") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func sendFeedback(_ sender: Any?) {
        if let url = URL(string: "mailto:opa@mrbarkan.com?subject=CrateDigger%20Feedback") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func setAppearanceMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw)
        else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
        // The checkmark is set in validateMenuItem when the menu next opens.
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
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
        case #selector(revealSelectionInFinder(_:)),
             #selector(convertSelected(_:)),
             #selector(transferToDevice(_:)):
            return (mainWindowController?.currentSelectionURL() != nil)
                && !(mainWindowController?.isConversionRunning ?? false)
        case #selector(cancelConversion(_:)):
            return mainWindowController?.isConversionRunning ?? false
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
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem(title: "Preferences…", action: #selector(showPreferences(_:)), key: ","))
        appMenu.addItem(.separator())
        let appearanceMenuItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        let currentMode = AppearanceMode.current
        for mode in AppearanceMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(setAppearanceMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == currentMode) ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceMenuItem.submenu = appearanceMenu
        appMenu.addItem(appearanceMenuItem)
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
        // Match the order shown in the OLED view switcher (VU is hidden in the chrome).
        let displayedViews: [(OLEDView, String)] = [
            (.nowPlaying, "1"),
            (.conversion, "2"),
            (.scan, "3")
        ]
        for (view, key) in displayedViews {
            let item = makeItem(title: "\(view.label) Display", action: #selector(selectOLEDView(_:)), key: key)
            item.representedObject = view.rawValue
            viewMenu.addItem(item)
        }
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
        let repeatItem = makeItem(title: "Cycle Repeat Mode", action: #selector(cycleRepeatMode(_:)), key: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .option]
        playbackMenu.addItem(repeatItem)
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
        engineMenuItem.submenu = engineMenu
        playbackMenu.addItem(engineMenuItem)

        playbackMenuItem.submenu = playbackMenu

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
        helpMenu.addItem(.separator())
        helpMenu.addItem(makeItem(title: "CrateDigger Help", action: #selector(openHelpPage(_:)), key: "?"))
        helpMenu.addItem(makeItem(title: "Send Feedback…", action: #selector(sendFeedback(_:))))
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
