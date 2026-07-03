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

    /// Finish or skip the tour (both buttons land here); just dismisses — the
    /// follow-up work runs from `welcomeTourDidDismiss()` so it's sequenced by
    /// the sheet's real dismissal, not a timer.
    func completeWelcomeTour() {
        showingWelcomeTour = false
    }

    /// The tour sheet's `onDismiss`: mark it seen, then chain into folder
    /// setup on first run — or, for an already-set-up library (upgrade or
    /// replay), make sure the starter album the tour mentions exists.
    func welcomeTourDidDismiss() {
        prefs.hasSeenWelcomeTour = true
        if !prefs.hasCompletedFirstRunSetup {
            showingOnboarding = true
        } else {
            installStarterContentIfNeeded()
        }
    }

    // MARK: - Starter content

    /// The bundled starter album ("The CrateDigger Manual"): the StarterCrate
    /// folder inside whichever SPM resource bundle sits next to the app
    /// binary / in Contents/Resources. Found by scanning `*.bundle` rather
    /// than hardcoding the generated bundle name (and not via `Bundle.module`,
    /// which traps when the bundle is missing) so a package rename or a
    /// packaged app without resources degrades to a no-op.
    private var starterAlbumSourceURL: URL? {
        let fm = FileManager.default
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            guard let base,
                  let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries where entry.pathExtension == "bundle" {
                let folder = entry.appendingPathComponent("StarterCrate", isDirectory: true)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return folder
                }
            }
        }
        return nil
    }

    /// Copy the bundled starter album into the Local Library and file it into
    /// the Personal Crate, so a brand-new install has something to play (and
    /// the album art doubles as a quick-reference manual). File I/O and the
    /// scan run off the main actor; the installed flag is only latched once
    /// the tracks are actually in the crate, so a failed scan retries on the
    /// next entry point. Quietly does nothing when the resource bundle isn't
    /// present.
    func installStarterContentIfNeeded() {
        guard !prefs.starterContentInstalled else { return }
        guard let source = starterAlbumSourceURL,
              let libraryRoot = managedLibraryFolderURL else { return }

        let artistFolder = libraryRoot.appendingPathComponent("MRBRKN", isDirectory: true)
        let albumFolder = artistFolder.appendingPathComponent("The CrateDigger Manual", isDirectory: true)
        let scanner = self.scanner

        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            do {
                if !fm.fileExists(atPath: albumFolder.path) {
                    try fm.createDirectory(at: artistFolder, withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: albumFolder)
                }
            } catch {
                AppLog.library.warning("Couldn't install starter album: \(String(describing: error), privacy: .public)")
                return
            }
            let scanned = await scanner.scanFolder(albumFolder)
            guard !scanned.isEmpty else {
                AppLog.library.warning("Starter album copied but scan found no tracks; will retry later.")
                return
            }
            await self?.fileStarterTracks(scanned)
        }
    }

    /// Merge the scanned starter tracks into the Personal Crate, then latch
    /// the installed flag.
    private func fileStarterTracks(_ scanned: [LoadedTrack]) {
        for track in scanned {
            if let art = track.metadata.artwork, !art.data.isEmpty {
                artworkService.ingest(art)
            }
        }
        let crateName = Self.personalCrateName
        let existing = loadCrateTracks(name: crateName)
        let existingPaths = Set(existing.map { $0.track.fileURL.standardizedFileURL.path })
        let fresh = scanned.filter {
            !existingPaths.contains($0.track.fileURL.standardizedFileURL.path)
        }
        if !fresh.isEmpty {
            saveCrateTracks(existing + fresh, name: crateName)
            refreshAvailableCrates()
            selectSource(currentSource)
        }
        prefs.starterContentInstalled = true
    }
}
