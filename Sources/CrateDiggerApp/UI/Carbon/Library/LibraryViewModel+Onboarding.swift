import AppKit
import CrateDiggerCore

/// First-run onboarding: pick the three independent folders (Local Library,
/// Library File location, Default Output) or accept defaults. Reuses the
/// security-scoped bookmark helpers; each folder is independent (e.g. the Local
/// Library can be an external drive while the index files stay local).
@MainActor
extension LibraryViewModel {

    // MARK: - Default locations (under ~/Music/CrateDigger)

    private var libraryHomeURL: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("CrateDigger")
    }
    var defaultLocalLibraryURL: URL { libraryHomeURL.appendingPathComponent("Library") }
    var defaultLibraryFileURL: URL { libraryHomeURL.appendingPathComponent("Crates") }
    var defaultOutputURL: URL { libraryHomeURL.appendingPathComponent("Converted") }

    // MARK: - Current values (resolved bookmark, or the default path)

    private func resolved(_ data: Data?) -> URL? {
        data.flatMap { PreferencesStore.resolveBookmark($0)?.url }
    }

    var localLibraryIsSet: Bool { prefs.managedLibraryFolderBookmark != nil }
    var libraryFileIsSet: Bool { prefs.cratesIndexFolderBookmark != nil }
    var outputIsSet: Bool { prefs.savedOutputDestinationBookmark != nil }

    var localLibraryDisplayPath: String {
        resolved(prefs.managedLibraryFolderBookmark)?.path ?? defaultLocalLibraryURL.path
    }
    var libraryFileDisplayPath: String {
        resolved(prefs.cratesIndexFolderBookmark)?.path ?? defaultLibraryFileURL.path
    }
    var outputDisplayPath: String {
        resolved(prefs.savedOutputDestinationBookmark)?.path ?? defaultOutputURL.path
    }

    // MARK: - Folder pickers

    private func pickFolder(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.message = message
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func storeBookmark(_ url: URL, set: (Data?) -> Void) {
        guard let data = try? PreferencesStore.makeBookmark(for: url) else {
            appAlert = .error(title: "Couldn't Use Folder", message: "Failed to remember “\(url.lastPathComponent)”.")
            return
        }
        set(data)
        objectWillChange.send()
    }

    func chooseLocalLibraryFolder() {
        guard let url = pickFolder(title: "Local Library Folder",
                                   message: "Where your albums and tracks live. This can be an external drive.")
        else { return }
        storeBookmark(url) { prefs.managedLibraryFolderBookmark = $0 }
    }

    func chooseLibraryFileFolder() {
        guard let url = pickFolder(title: "Library File Location",
                                   message: "Where crate index (.cdlib) files are saved. Keep this on a local disk.")
        else { return }
        storeBookmark(url) { prefs.cratesIndexFolderBookmark = $0 }
        refreshAvailableCrates()
    }

    func chooseOutputFolder() {
        guard let url = pickFolder(title: "Default Output Folder",
                                   message: "Where converted files go by default.")
        else { return }
        storeBookmark(url) { prefs.savedOutputDestinationBookmark = $0 }
    }

    /// "I already have a library" — point at a folder that already holds `.cdlib`
    /// crates and adopt it as the Library File location.
    func openExistingLibrary() {
        guard let url = pickFolder(title: "Open Existing Library",
                                   message: "Choose a folder that already contains your crate index (.cdlib) files.")
        else { return }
        storeBookmark(url) { prefs.cratesIndexFolderBookmark = $0 }
        refreshAvailableCrates()
    }

    // MARK: - Finish

    /// Fill any unchosen folder with its default (created on disk), mark setup
    /// complete, and ensure a Personal Crate exists.
    func completeFirstRunSetup() {
        let fm = FileManager.default
        if prefs.managedLibraryFolderBookmark == nil {
            try? fm.createDirectory(at: defaultLocalLibraryURL, withIntermediateDirectories: true)
            prefs.managedLibraryFolderBookmark = try? PreferencesStore.makeBookmark(for: defaultLocalLibraryURL)
        }
        if prefs.cratesIndexFolderBookmark == nil {
            try? fm.createDirectory(at: defaultLibraryFileURL, withIntermediateDirectories: true)
            prefs.cratesIndexFolderBookmark = try? PreferencesStore.makeBookmark(for: defaultLibraryFileURL)
        }
        if prefs.savedOutputDestinationBookmark == nil {
            try? fm.createDirectory(at: defaultOutputURL, withIntermediateDirectories: true)
            prefs.savedOutputDestinationBookmark = try? PreferencesStore.makeBookmark(for: defaultOutputURL)
        }
        prefs.hasCompletedFirstRunSetup = true
        refreshAvailableCrates()
        showingOnboarding = false
        installStarterContentIfNeeded()
    }

    // MARK: - Welcome tour

    /// Replay entry point (Help ▸ Welcome Tour, Preferences "Show Tour Now").
    func startWelcomeTour() {
        showingWelcomeTour = true
    }

    /// Finish or skip the tour. On first run this chains straight into the
    /// folder-setup sheet (after the tour sheet's dismissal animation).
    func completeWelcomeTour() {
        prefs.hasSeenWelcomeTour = true
        showingWelcomeTour = false
        guard !prefs.hasCompletedFirstRunSetup else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.prefs.hasCompletedFirstRunSetup else { return }
            self.showingOnboarding = true
        }
    }

    // MARK: - Starter content

    /// The bundled starter album ("The CrateDigger Manual"), shipped as an SPM
    /// resource. Looked up manually — not via `Bundle.module` — so a packaged
    /// app missing the resource bundle degrades to a no-op instead of trapping.
    private var starterAlbumSourceURL: URL? {
        let bundleName = "CrateDigger_CrateDiggerApp.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for base in candidates {
            guard let base else { continue }
            let folder = base
                .appendingPathComponent(bundleName, isDirectory: true)
                .appendingPathComponent("StarterCrate", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return folder
            }
        }
        return nil
    }

    /// Copy the bundled starter album into the Local Library and file it into
    /// the Personal Crate, so a brand-new install has something to play (and
    /// the album art doubles as a quick-reference manual). Runs at most once;
    /// quietly does nothing when the resource bundle isn't present.
    func installStarterContentIfNeeded() {
        guard !prefs.starterContentInstalled else { return }
        guard let source = starterAlbumSourceURL,
              let libraryRoot = managedLibraryFolderURL else { return }

        let fm = FileManager.default
        let artistFolder = libraryRoot.appendingPathComponent("MRBRKN", isDirectory: true)
        let albumFolder = artistFolder.appendingPathComponent("The CrateDigger Manual", isDirectory: true)
        do {
            if !fm.fileExists(atPath: albumFolder.path) {
                try fm.createDirectory(at: artistFolder, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: albumFolder)
            }
        } catch {
            AppLog.library.warning("Couldn't install starter album: \(String(describing: error), privacy: .public)")
            return
        }
        prefs.starterContentInstalled = true

        Task { [weak self] in
            guard let self else { return }
            let scanned = await self.scanner.scanFolder(albumFolder)
            await MainActor.run {
                guard !scanned.isEmpty else { return }
                for track in scanned {
                    if let art = track.metadata.artwork, !art.data.isEmpty {
                        self.artworkService.ingest(art)
                    }
                }
                let crateName = "Personal Crate"
                let existing = self.loadCrateTracks(name: crateName)
                let existingPaths = Set(existing.map { $0.track.fileURL.standardizedFileURL.path })
                let fresh = scanned.filter {
                    !existingPaths.contains($0.track.fileURL.standardizedFileURL.path)
                }
                guard !fresh.isEmpty else { return }
                self.saveCrateTracks(existing + fresh, name: crateName)
                self.refreshAvailableCrates()
                self.selectSource(self.currentSource)
            }
        }
    }
}
