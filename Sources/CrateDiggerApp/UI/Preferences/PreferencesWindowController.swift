import AppKit
import CrateDiggerCore
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
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

private struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RemoteLibraryPreferencesView()
                .tabItem { Label("Remote", systemImage: "cloud") }
            LastFMPreferencesView()
                .tabItem { Label("Last.fm", systemImage: "music.note.house") }
            AudioPreferencesView()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ShortcutsPreferencesView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DevicesPreferencesView()
                .tabItem { Label("Devices", systemImage: "externaldrive") }
            AdvancedPreferencesView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(minWidth: 800, minHeight: 580)
        .padding(20)
    }
}

private struct GeneralPreferencesView: View {
    @State private var libraryDisplayPath: String = "Not set"
    @State private var libraryFolderExists: Bool = true
    @State private var cratesDisplayPath: String = "Not set (Defaulting to App Support)"
    @State private var cratesFolderExists: Bool = true
    @State private var copyOnImport: Bool = false
    @State private var deleteOriginals: Bool = false
    @State private var organiseByArtist: Bool = true
    @State private var keepOrganised: Bool = true

    var body: some View {
        Form {
            Section("Default output folder") {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(displayPath == "Not set" ? .secondary : .primary)
                    Button("Choose…") { chooseFolder() }
                    Button("Reveal") { revealFolder() }
                        .disabled(currentURL == nil)
                    Button("Clear") { clearFolder() }
                        .disabled(currentURL == nil)
                }
                Text("Used as the destination for converted files. The first conversion will prompt you if this is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Library Files (Crates Index)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Crates location:")
                            .frame(width: 150, alignment: .leading)
                        
                        HStack(spacing: 6) {
                            Text(cratesDisplayPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(cratesDisplayPath.hasPrefix("Not set") ? .secondary : .primary)
                            
                            if !cratesFolderExists {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Crates folder not found or inaccessible")
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                        
                        Button("Choose…") { chooseCratesFolder() }
                    }
                    Text("Contains all your crate library index files (.cdlib). Defaults to standard Application Support directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library Folder (Music Storage)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Library folder location:")
                            .frame(width: 150, alignment: .leading)
                        
                        HStack(spacing: 6) {
                            Text(libraryDisplayPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(libraryDisplayPath == "Not set" ? .secondary : .primary)
                            
                            if !libraryFolderExists {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Library folder not found or inaccessible")
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                        
                        Button("Choose…") { chooseLibraryFolder() }
                    }
                    .padding(.bottom, 4)

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
                            NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerMoveLibrary"), object: nil)
                        }
                        Button("Consolidate Library…") {
                            NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerConsolidateLibrary"), object: nil)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CrateDiggerLibraryFolderChanged"))) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CrateDiggerCratesFolderChanged"))) { _ in
            refresh()
        }
    }

    private var currentURL: URL? {
        guard let data = PreferencesStore.shared.savedOutputDestinationBookmark else { return nil }
        return PreferencesStore.resolveBookmark(data)?.url
    }

    private var displayPath: String {
        currentURL?.path ?? "Not set"
    }

    private var currentLibraryURL: URL? {
        guard let data = PreferencesStore.shared.managedLibraryFolderBookmark else { return nil }
        return PreferencesStore.resolveBookmark(data)?.url
    }

    private var currentCratesURL: URL? {
        guard let data = PreferencesStore.shared.cratesIndexFolderBookmark else { return nil }
        return PreferencesStore.resolveBookmark(data)?.url
    }

    private func refresh() {
        let libURL = currentLibraryURL
        libraryDisplayPath = libURL?.path ?? "Not set"
        if let url = libURL {
            libraryFolderExists = FileManager.default.fileExists(atPath: url.path)
        } else {
            libraryFolderExists = true
        }

        let cratesURL = currentCratesURL
        cratesDisplayPath = cratesURL?.path ?? "Not set (Defaulting to App Support)"
        if let url = cratesURL {
            cratesFolderExists = FileManager.default.fileExists(atPath: url.path)
        } else {
            cratesFolderExists = true
        }

        copyOnImport = PreferencesStore.shared.copyOnImport
        deleteOriginals = PreferencesStore.shared.deleteOriginalsAfterCopy
        organiseByArtist = PreferencesStore.shared.organiseByAlbumArtist
        keepOrganised = PreferencesStore.shared.keepLibraryOrganised
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose default output folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PreferencesStore.makeBookmark(for: url)
            PreferencesStore.shared.savedOutputDestinationBookmark = data
            refresh()
        } catch {
            AppLog.prefs.warning("Could not bookmark default output folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose default library folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PreferencesStore.makeBookmark(for: url)
            PreferencesStore.shared.managedLibraryFolderBookmark = data
            
            // Notify the main view model
            NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerLibraryFolderChanged"), object: url)
            
            refresh()
        } catch {
            AppLog.prefs.warning("Could not bookmark managed library folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseCratesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose default crates index folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PreferencesStore.makeBookmark(for: url)
            PreferencesStore.shared.cratesIndexFolderBookmark = data
            
            // Notify the main view model
            NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerCratesFolderChanged"), object: url)
            
            refresh()
        } catch {
            AppLog.prefs.warning("Could not bookmark crates index folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func revealFolder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func clearFolder() {
        PreferencesStore.shared.savedOutputDestinationBookmark = nil
        refresh()
    }
}

private struct AdvancedPreferencesView: View {
    @State private var ffmpegPath: String = ""
    @State private var ffprobePath: String = ""
    @State private var clickSoundsEnabled: Bool = PreferencesStore.shared.clickSoundsEnabled
    @State private var showHoverTips: Bool = PreferencesStore.shared.showHoverTips
    @State private var simpleHorizontalVU: Bool = PreferencesStore.shared.savedSimpleHorizontalVU
    @State private var eqEnabled: Bool = PreferencesStore.shared.savedEQEnabled
    @State private var cdAnimationSpeed: CDAnimationSpeed = PreferencesStore.shared.cdAnimationSpeed
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Interface") {
                Toggle("Click sounds", isOn: $clickSoundsEnabled)
                    .onChange(of: clickSoundsEnabled) { newValue in
                        PreferencesStore.shared.clickSoundsEnabled = newValue
                    }
                Text("Plays short hardware-style click sounds when you press chassis buttons. Off if you'd rather have silent chrome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show hover tips", isOn: $showHoverTips)
                    .onChange(of: showHoverTips) { newValue in
                        PreferencesStore.shared.showHoverTips = newValue
                    }
                Text("Shows a short tooltip explaining what a control does when you hover over it. On by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Simple horizontal VU meter", isOn: $simpleHorizontalVU)
                    .onChange(of: simpleHorizontalVU) { newValue in
                        PreferencesStore.shared.savedSimpleHorizontalVU = newValue
                    }
                Text("Show the classic left/right horizontal VU bars in the footer instead of the vertical spectrum analyzer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("CD Animation Speed", selection: $cdAnimationSpeed) {
                    ForEach(CDAnimationSpeed.allCases, id: \.self) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .onChange(of: cdAnimationSpeed) { newValue in
                    PreferencesStore.shared.cdAnimationSpeed = newValue
                    NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerCDSpeedChanged"), object: newValue)
                }
                Text("Controls the spinning rate of the optical CD player animation during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Equalizer") {
                Toggle("Apply equalizer to playback", isOn: $eqEnabled)
                    .onChange(of: eqEnabled) { _ in saveEQ() }
                Text("A real 12-band equalizer applied to what you hear. Click the EQ panel in the footer to open the graphic equalizer and set the bands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("External tools") {
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
                Button("Open Console for CrateDigger") {
                    openConsole()
                }
                Text("Opens Console.app filtered to com.cratedigger.app for live log inspection.")
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
        cdAnimationSpeed = PreferencesStore.shared.cdAnimationSpeed
        showHoverTips = PreferencesStore.shared.showHoverTips
    }

    private func saveEQ() {
        // Only the master enable lives here; the band gains are owned by the
        // graphic-EQ modal (writing them from here could stomp newer edits).
        PreferencesStore.shared.savedEQEnabled = eqEnabled
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerEQChanged"), object: nil)
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

// MARK: - Remote Library Preferences

struct RemoteLibraryPreferencesView: View {
    @State private var serverURL = PreferencesStore.shared.subsonicURL ?? ""
    @State private var username = PreferencesStore.shared.subsonicUsername ?? ""
    @State private var password = PreferencesStore.shared.subsonicPassword ?? ""
    @State private var pingStatus = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Subsonic / Navidrome Connection") {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Configuration") {
                        saveConfig()
                    }
                    Button("Test Connection") {
                        testConnection()
                    }
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
        .formStyle(.grouped)
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

// MARK: - Last.fm Preferences

struct LastFMPreferencesView: View {
    @State private var username = PreferencesStore.shared.lastFmUsername ?? ""
    @State private var sessionKey = PreferencesStore.shared.lastFmSessionKey ?? ""
    @State private var linking = false
    @State private var requestToken = ""
    @State private var statusText = ""

    var body: some View {
        Form {
            Section("Last.fm Scrobbler") {
                if sessionKey.isEmpty {
                    Text("Connect your Last.fm account to log your plays automatically.")
                        .font(.body)
                    
                    if requestToken.isEmpty {
                        Button("Link Account…") {
                            startAuthFlow()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. Authorize CrateDigger in the opened browser window.")
                            Text("2. Click below when finished to complete the link.")
                            HStack {
                                Button("Confirm Link") {
                                    confirmAuth()
                                }
                                .disabled(linking)
                                
                                Button("Cancel") {
                                    requestToken = ""
                                    statusText = ""
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Linked account: \(username)")
                            .font(.headline)
                        Button("Unlink Account", role: .destructive) {
                            unlinkAccount()
                        }
                    }
                }

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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

// MARK: - Audio Preferences

struct AudioPreferencesView: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedUID = PreferencesStore.shared.selectedOutputDeviceUID ?? ""

    var body: some View {
        Form {
            Section("Output Audio Device") {
                Picker("Device", selection: $selectedUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: selectedUID) { newValue in
                    PreferencesStore.shared.selectedOutputDeviceUID = newValue.isEmpty ? nil : newValue
                    // Notify active player if available
                    // We will wire this to LibraryViewModel or directly via Notification
                    NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerAudioDeviceChanged"), object: newValue)
                }
                
                Button("Refresh Devices") {
                    refreshDevices()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshDevices()
        }
    }

    private func refreshDevices() {
        devices = AudioOutputManager().getOutputDevices()
    }
}

// MARK: - Shortcuts Preferences

struct ShortcutsPreferencesView: View {
    @State private var shortcuts = PreferencesStore.shared.keyboardShortcuts
    @State private var editingAction: String? = nil

    private let actions = [
        ("Play / Pause", "playPause"),
        ("Next Track", "next"),
        ("Previous Track", "previous"),
        ("Volume Up", "volumeUp"),
        ("Volume Down", "volumeDown"),
        ("Seek Forward", "seekForward"),
        ("Seek Backward", "seekBackward")
    ]

    var body: some View {
        Form {
            Section("Custom Keyboard Shortcuts") {
                Text("Click on a row to customize the key for each action. Press Escape to clear.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                List {
                    ForEach(actions, id: \.1) { name, key in
                        HStack {
                            Text(name)
                            Spacer()
                            if editingAction == key {
                                Text("Press any key…")
                                    .foregroundColor(.blue)
                                    .fontWeight(.bold)
                            } else {
                                Text(shortcuts[key] ?? defaultKey(for: key))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingAction = key
                        }
                    }
                }
                .frame(height: 240)
            }
        }
        .formStyle(.grouped)
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

    private func defaultKey(for key: String) -> String {
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
}

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
