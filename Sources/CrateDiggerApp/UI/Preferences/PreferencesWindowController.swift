import AppKit
import CrateDiggerCore
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CrateDigger Preferences"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CrateDiggerPreferences")

        let host = NSHostingController(rootView: PreferencesView())
        window.contentViewController = host

        self.init(window: window)
    }
}

/// Six focused tabs: where things live (General), how the app looks & sounds
/// (Interface), how it plays (Playback), external accounts (Integrations),
/// transfer targets (Devices), and the sharp tools (Advanced).
private struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            InterfacePreferencesView()
                .tabItem { Label("Interface", systemImage: "paintbrush") }
            PlaybackPreferencesView()
                .tabItem { Label("Playback", systemImage: "speaker.wave.2") }
            IntegrationsPreferencesView()
                .tabItem { Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted") }
            DevicesPreferencesView()
                .tabItem { Label("Devices", systemImage: "externaldrive") }
            AdvancedPreferencesView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 780, height: 580)
    }
}

// MARK: - Shared folder row

/// One folder setting: leading label, current path (with a missing-folder
/// warning), and Choose / optional Reveal / optional Clear actions. Shared by
/// all three folder settings so they read identically — compact single rows,
/// with the explanation in a hover tooltip rather than a caption line.
private struct FolderSettingRow: View {
    let label: String
    let url: URL?
    /// Computed once by the owning view's refresh() — not per render, since a
    /// folder on an unmounted network volume can make fileExists stall.
    let exists: Bool
    let placeholder: String
    let chooseTitle: String
    var onChoose: (URL) -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 118, alignment: .leading)

            HStack(spacing: 6) {
                Text(url?.path ?? placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                if !exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Folder not found or inaccessible")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…") { choose() }
            Button("Reveal") { reveal() }
                .disabled(url == nil || !exists)
            if let onClear {
                Button("Clear") { onClear() }
                    .disabled(url == nil)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = chooseTitle
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        onChoose(chosen)
    }

    private func reveal() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - General (folders & library behavior)

private struct GeneralPreferencesView: View {
    @State private var libraryURL: URL?
    @State private var libraryExists = true
    @State private var cratesURL: URL?
    @State private var cratesExists = true
    @State private var outputURL: URL?
    @State private var outputExists = true
    @State private var copyOnImport: Bool = false
    @State private var deleteOriginals: Bool = false
    @State private var organiseByArtist: Bool = true
    @State private var keepOrganised: Bool = true
    @State private var thumbnailCacheSize: String = "—"

    var body: some View {
        Form {
            // One compact section for all three folders — no scrolling. The
            // longer explanations live in hover tooltips (.help).
            Section("Folders") {
                FolderSettingRow(
                    label: "Local Library",
                    url: libraryURL,
                    exists: libraryExists,
                    placeholder: "Not set",
                    chooseTitle: "Choose library folder",
                    onChoose: { url in
                        store(url) { PreferencesStore.shared.managedLibraryFolderBookmark = $0 }
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CrateDiggerLibraryFolderChanged"), object: url)
                    }
                )
                .help("Where your music files live — can be an external drive.")

                FolderSettingRow(
                    label: "Library Files",
                    url: cratesURL,
                    exists: cratesExists,
                    placeholder: "Not set (defaults to Application Support)",
                    chooseTitle: "Choose crates index folder",
                    onChoose: { url in
                        store(url) { PreferencesStore.shared.cratesIndexFolderBookmark = $0 }
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CrateDiggerCratesFolderChanged"), object: url)
                    }
                )
                .help("Where crate index files are saved. Keep this on a local disk.")

                FolderSettingRow(
                    label: "Default Output",
                    url: outputURL,
                    exists: outputExists,
                    placeholder: "Not set",
                    chooseTitle: "Choose default output folder",
                    onChoose: { url in
                        store(url) { PreferencesStore.shared.savedOutputDestinationBookmark = $0 }
                    },
                    onClear: {
                        PreferencesStore.shared.savedOutputDestinationBookmark = nil
                        refresh()
                    }
                )
                .help("Destination for converted files. The first conversion prompts you if this is empty.")
            }

            Section("Importing & Organizing") {
                Toggle("Copy newly added tracks to the library folder", isOn: $copyOnImport)
                    .onChange(of: copyOnImport) { newValue in
                        PreferencesStore.shared.copyOnImport = newValue
                    }
                Toggle("Delete originals after copying", isOn: $deleteOriginals)
                    .padding(.leading, 20)
                    .disabled(!copyOnImport)
                    .onChange(of: deleteOriginals) { newValue in
                        PreferencesStore.shared.deleteOriginalsAfterCopy = newValue
                    }
                Toggle("Organise by Album Artist", isOn: $organiseByArtist)
                    .onChange(of: organiseByArtist) { newValue in
                        PreferencesStore.shared.organiseByAlbumArtist = newValue
                    }
                Toggle("Keep library folder organised when tags are edited", isOn: $keepOrganised)
                    .onChange(of: keepOrganised) { newValue in
                        PreferencesStore.shared.keepLibraryOrganised = newValue
                    }
                HStack(spacing: 12) {
                    Button("Move Library…") {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CrateDiggerMoveLibrary"), object: nil)
                    }
                    Button("Consolidate Library…") {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CrateDiggerConsolidateLibrary"), object: nil)
                    }
                }
            }

            Section("Artwork Cache") {
                LabeledContent("Cached thumbnails") {
                    HStack(spacing: 12) {
                        Text(thumbnailCacheSize)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Clean…") { cleanThumbnailCache() }
                    }
                }
                .help("Covers are stored with your music; this is only a thumbnail cache for fast, offline browsing. Cleaning it is always safe — thumbnails come back as you browse.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("CrateDiggerLibraryFolderChanged"))) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("CrateDiggerCratesFolderChanged"))) { _ in refresh() }
    }

    private func store(_ url: URL, into setter: (Data?) -> Void) {
        do {
            setter(try PreferencesStore.makeBookmark(for: url))
            refresh()
        } catch {
            AppLog.prefs.warning("Could not bookmark folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func resolved(_ data: Data?) -> URL? {
        data.flatMap { PreferencesStore.resolveBookmark($0)?.url }
    }

    private func refresh() {
        let prefs = PreferencesStore.shared
        let fm = FileManager.default
        libraryURL = resolved(prefs.managedLibraryFolderBookmark)
        libraryExists = libraryURL.map { fm.fileExists(atPath: $0.path) } ?? true
        cratesURL = resolved(prefs.cratesIndexFolderBookmark)
        cratesExists = cratesURL.map { fm.fileExists(atPath: $0.path) } ?? true
        outputURL = resolved(prefs.savedOutputDestinationBookmark)
        outputExists = outputURL.map { fm.fileExists(atPath: $0.path) } ?? true
        copyOnImport = prefs.copyOnImport
        deleteOriginals = prefs.deleteOriginalsAfterCopy
        organiseByArtist = prefs.organiseByAlbumArtist
        keepOrganised = prefs.keepLibraryOrganised
        refreshThumbnailCacheSize()
    }

    private func refreshThumbnailCacheSize() {
        let bytes = ArtworkStore(directory: ArtworkStore.defaultDirectory).diskSizeBytes()
        thumbnailCacheSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func cleanThumbnailCache() {
        ArtworkStore(directory: ArtworkStore.defaultDirectory).clear()
        refreshThumbnailCacheSize()
    }
}

// MARK: - Interface (look & feel)

private struct InterfacePreferencesView: View {
    @State private var clickSoundsEnabled: Bool = PreferencesStore.shared.clickSoundsEnabled
    @State private var showHoverTips: Bool = PreferencesStore.shared.showHoverTips
    @State private var simpleHorizontalVU: Bool = PreferencesStore.shared.savedSimpleHorizontalVU
    @State private var cdAnimationSpeed: CDAnimationSpeed = PreferencesStore.shared.cdAnimationSpeed
    @State private var showTourAtLaunch: Bool = !PreferencesStore.shared.hasSeenWelcomeTour

    var body: some View {
        Form {
            Section("Chassis") {
                Toggle("Click sounds", isOn: $clickSoundsEnabled)
                    .onChange(of: clickSoundsEnabled) { newValue in
                        PreferencesStore.shared.clickSoundsEnabled = newValue
                    }
                Text("Short hardware-style clicks when you press chassis buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show hover tips", isOn: $showHoverTips)
                    .onChange(of: showHoverTips) { newValue in
                        PreferencesStore.shared.showHoverTips = newValue
                    }
                Text("A short tooltip explaining a control when you hover over it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meters & Motion") {
                Toggle("Simple horizontal VU meter", isOn: $simpleHorizontalVU)
                    .onChange(of: simpleHorizontalVU) { newValue in
                        PreferencesStore.shared.savedSimpleHorizontalVU = newValue
                    }
                Text("Classic left/right VU bars in the footer instead of the vertical spectrum analyzer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("CD animation speed", selection: $cdAnimationSpeed) {
                    ForEach(CDAnimationSpeed.allCases, id: \.self) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .onChange(of: cdAnimationSpeed) { newValue in
                    PreferencesStore.shared.cdAnimationSpeed = newValue
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CrateDiggerCDSpeedChanged"), object: newValue)
                }
            }

            Section("Welcome Tour") {
                Toggle("Show the welcome tour at next launch", isOn: $showTourAtLaunch)
                    .onChange(of: showTourAtLaunch) { newValue in
                        PreferencesStore.shared.hasSeenWelcomeTour = !newValue
                    }
                HStack {
                    Text("Or replay it right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Tour Now") {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("CrateDiggerShowWelcomeTour"), object: nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    /// Re-read everything from the store: the window controller is cached
    /// across opens, so @State would otherwise go stale after e.g. a
    /// Reset Preferences from the Advanced tab.
    private func refresh() {
        let prefs = PreferencesStore.shared
        clickSoundsEnabled = prefs.clickSoundsEnabled
        showHoverTips = prefs.showHoverTips
        simpleHorizontalVU = prefs.savedSimpleHorizontalVU
        cdAnimationSpeed = prefs.cdAnimationSpeed
        showTourAtLaunch = !prefs.hasSeenWelcomeTour
    }
}

// MARK: - Playback (device, EQ, shortcuts)

private struct PlaybackPreferencesView: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedUID = PreferencesStore.shared.selectedOutputDeviceUID ?? ""
    @State private var eqEnabled: Bool = PreferencesStore.shared.savedEQEnabled
    @State private var shortcuts = PreferencesStore.shared.keyboardShortcuts
    @State private var editingAction: String? = nil

    private let actions = [
        ("Play / Pause", "playPause"),
        ("Next Track", "next"),
        ("Previous Track", "previous"),
        ("Volume Up", "volumeUp"),
        ("Volume Down", "volumeDown"),
        ("Seek Forward", "seekForward"),
        ("Seek Backward", "seekBackward"),
    ]

    var body: some View {
        Form {
            Section("Output Device") {
                Picker("Play audio through", selection: $selectedUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onChange(of: selectedUID) { newValue in
                    PreferencesStore.shared.selectedOutputDeviceUID = newValue.isEmpty ? nil : newValue
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CrateDiggerAudioDeviceChanged"), object: newValue)
                }
                Button("Refresh Devices") { refreshDevices() }
            }

            Section("Equalizer") {
                Toggle("Apply equalizer to playback", isOn: $eqEnabled)
                    .onChange(of: eqEnabled) { _ in saveEQ() }
                Text("A real 12-band equalizer applied to what you hear. Click the EQ panel in the footer to set the bands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcuts") {
                Text("Click a row, then press a key to customize it. Press Escape to clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(actions, id: \.1) { name, key in
                    HStack {
                        Text(name)
                        Spacer()
                        if editingAction == key {
                            Text("Press any key…")
                                .foregroundColor(.blue)
                                .fontWeight(.bold)
                        } else {
                            Text(shortcutDisplay(for: key))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingAction = key }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDevices() }
        .background(
            ShortcutKeyHandler { event in
                guard let editing = editingAction else { return }

                if event.keyCode == 53 { // Escape
                    shortcuts[editing] = ""
                    PreferencesStore.shared.keyboardShortcuts = shortcuts
                    editingAction = nil
                    return
                }

                if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                    var display = chars.uppercased()
                    if event.keyCode == 49 { display = "Space" }
                    else if event.keyCode == 124 { display = "Right Arrow" }
                    else if event.keyCode == 123 { display = "Left Arrow" }
                    else if event.keyCode == 126 { display = "Up Arrow" }
                    else if event.keyCode == 125 { display = "Down Arrow" }

                    shortcuts[editing] = display
                    PreferencesStore.shared.keyboardShortcuts = shortcuts
                    editingAction = nil
                }
            }
        )
    }

    private func shortcutDisplay(for key: String) -> String {
        if let custom = shortcuts[key], !custom.isEmpty { return custom }
        switch key {
        case "playPause": return "Space"
        case "next": return "Right Arrow"
        case "previous": return "Left Arrow"
        case "volumeUp": return "Up Arrow"
        case "volumeDown": return "Down Arrow"
        case "seekForward": return "F"
        case "seekBackward": return "B"
        default: return "None"
        }
    }

    private func refreshDevices() {
        devices = AudioOutputManager().getOutputDevices()
    }

    private func saveEQ() {
        // Only the master enable lives here; the band gains are owned by the
        // graphic-EQ modal (writing them from here could stomp newer edits).
        PreferencesStore.shared.savedEQEnabled = eqEnabled
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerEQChanged"), object: nil)
    }
}

// MARK: - Integrations (Subsonic / Navidrome + Last.fm)

private struct IntegrationsPreferencesView: View {
    var body: some View {
        Form {
            SubsonicSettingsSection()
            LastFMSettingsSection()
        }
        .formStyle(.grouped)
    }
}

private struct SubsonicSettingsSection: View {
    @State private var serverURL = PreferencesStore.shared.subsonicURL ?? ""
    @State private var username = PreferencesStore.shared.subsonicUsername ?? ""
    @State private var password = PreferencesStore.shared.subsonicPassword ?? ""
    @State private var pingStatus = ""
    @State private var testing = false

    var body: some View {
        Section("Subsonic / Navidrome") {
            TextField("Server URL", text: $serverURL)
                .disableAutocorrection(true)
            TextField("Username", text: $username)
                .disableAutocorrection(true)
            SecureField("Password", text: $password)

            HStack {
                Button("Save Configuration") { saveConfig() }
                Button("Test Connection") { testConnection() }
                    .disabled(testing || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                if testing {
                    ProgressView().controlSize(.small)
                }
            }

            if !pingStatus.isEmpty {
                Text(pingStatus)
                    .font(.caption)
                    .foregroundColor(pingStatus.contains("Success") ? .green : .red)
            }
        }
    }

    private func saveConfig() {
        PreferencesStore.shared.subsonicURL = serverURL
        PreferencesStore.shared.subsonicUsername = username
        PreferencesStore.shared.subsonicPassword = password
        pingStatus = "Configuration Saved!"
    }

    private func testConnection() {
        testing = true
        pingStatus = "Testing connection..."
        let config = SubsonicConfig(url: serverURL, username: username, password: password)
        let client = SubsonicClient()

        Task {
            do {
                let ok = try await client.ping(config: config)
                await MainActor.run {
                    testing = false
                    pingStatus = ok ? "Success! Connected to server." : "Failed to connect. Check URL and credentials."
                    if ok {
                        saveConfig()
                    }
                }
            } catch {
                await MainActor.run {
                    testing = false
                    pingStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct LastFMSettingsSection: View {
    @State private var username = PreferencesStore.shared.lastFmUsername ?? ""
    @State private var sessionKey = PreferencesStore.shared.lastFmSessionKey ?? ""
    @State private var linking = false
    @State private var requestToken = ""
    @State private var statusText = ""

    var body: some View {
        Section("Last.fm Scrobbler") {
            if sessionKey.isEmpty {
                Text("Connect your Last.fm account to log your plays automatically.")

                if requestToken.isEmpty {
                    Button("Link Account…") { startAuthFlow() }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Authorize CrateDigger in the opened browser window.")
                        Text("2. Click below when finished to complete the link.")
                        HStack {
                            Button("Confirm Link") { confirmAuth() }
                                .disabled(linking)
                            Button("Cancel") {
                                requestToken = ""
                                statusText = ""
                            }
                        }
                    }
                }
            } else {
                Text("Linked account: \(username)")
                    .font(.headline)
                Button("Unlink Account", role: .destructive) { unlinkAccount() }
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func startAuthFlow() {
        let scrobbler = LastFMScrobbler()
        guard scrobbler.isConfigured else {
            statusText = "Last.fm is not configured in this build."
            return
        }

        // Last.fm desktop web auth: fetch a request token, open the browser for the
        // user to authorize it, then (in confirmAuth) exchange the token for a
        // session key. The API key/secret live in LastFMScrobbler, not here.
        statusText = "Redirecting to Last.fm..."

        Task {
            do {
                guard let token = try await scrobbler.fetchRequestToken() else {
                    await MainActor.run {
                        self.statusText = "Failed to obtain request token."
                    }
                    return
                }
                await MainActor.run {
                    self.requestToken = token
                    self.statusText = "Opened browser. Please authorize CrateDigger."
                    if let authURL = scrobbler.authorizationURL(forToken: token) {
                        NSWorkspace.shared.open(authURL)
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusText = "Network error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func confirmAuth() {
        linking = true
        statusText = "Completing authorization..."
        let scrobbler = LastFMScrobbler()

        Task {
            do {
                if let session = try await scrobbler.fetchSession(token: requestToken) {
                    await MainActor.run {
                        linking = false
                        PreferencesStore.shared.lastFmUsername = session.username
                        PreferencesStore.shared.lastFmSessionKey = session.sessionKey
                        self.username = session.username
                        self.sessionKey = session.sessionKey
                        self.statusText = "Linked successfully!"
                    }
                } else {
                    await MainActor.run {
                        linking = false
                        self.statusText = "Authorization not approved on Last.fm yet."
                    }
                }
            } catch {
                await MainActor.run {
                    linking = false
                    self.statusText = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func unlinkAccount() {
        PreferencesStore.shared.lastFmUsername = nil
        PreferencesStore.shared.lastFmSessionKey = nil
        username = ""
        sessionKey = ""
        requestToken = ""
        statusText = "Account unlinked."
    }
}

// MARK: - Advanced (tools, diagnostics, reset)

private struct AdvancedPreferencesView: View {
    @State private var ffmpegPath: String = ""
    @State private var ffprobePath: String = ""
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("External Tools") {
                LabeledContent("ffmpeg path") {
                    HStack {
                        TextField("Auto-detect", text: $ffmpegPath, onCommit: persistFFmpeg)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") { browseFor(.ffmpeg) }
                    }
                }
                LabeledContent("ffprobe path") {
                    HStack {
                        TextField("Auto-detect", text: $ffprobePath, onCommit: persistFFprobe)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") { browseFor(.ffprobe) }
                    }
                }
                Text("Leave blank to use the bundled binaries (or system PATH for development builds). Restart the app after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Open Console for CrateDigger") { openConsole() }
                Text("Opens Console.app; filter to com.cratedigger.app for live log inspection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset Preferences…") { showResetConfirmation = true }
                    .foregroundColor(.red)
                Text("Clears window position, recent folders, output folder, custom tool paths, and all UI state. Library files are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .alert("Reset all preferences?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This affects only CrateDigger settings. Your music and converted files are not touched.")
        }
    }

    private enum ToolPath {
        case ffmpeg
        case ffprobe
    }

    private func refresh() {
        ffmpegPath = PreferencesStore.shared.customFFmpegPath ?? ""
        ffprobePath = PreferencesStore.shared.customFFprobePath ?? ""
    }

    private func persistFFmpeg() {
        PreferencesStore.shared.customFFmpegPath = ffmpegPath.isEmpty ? nil : ffmpegPath
    }

    private func persistFFprobe() {
        PreferencesStore.shared.customFFprobePath = ffprobePath.isEmpty ? nil : ffprobePath
    }

    private func browseFor(_ tool: ToolPath) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.title = "Locate executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch tool {
        case .ffmpeg:
            ffmpegPath = url.path
            persistFFmpeg()
        case .ffprobe:
            ffprobePath = url.path
            persistFFprobe()
        }
    }

    private func openConsole() {
        // Open Console.app directly; the user filters to com.cratedigger.app from there.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }

    private func resetAll() {
        PreferencesStore.shared.resetAll()
        refresh()
    }
}

// MARK: - Shortcut capture helper

struct ShortcutKeyHandler: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class ShortcutNSView: NSView {
        var onKeyEvent: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            onKeyEvent?(event)
        }
    }
}
