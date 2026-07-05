import AppKit
import CrateDiggerCore

/// Missing / offline file handling. Instead of letting playback fail with a
/// dead-end "operation could not be completed", we detect the missing file up
/// front and offer the user something actionable — relocate it, or (only when
/// the volume is actually present) remove it. A disconnected drive is treated
/// as temporary: we never offer to remove those, so an unplugged library can't
/// be purged by accident.
extension LibraryViewModel {

    /// Returns `true` (and presents a prompt) when the track's file is missing,
    /// so callers can bail out before attempting playback.
    func presentIfFileMissing(_ track: LoadedTrack) -> Bool {
        let url = track.track.fileURL
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { return false }
        presentMissingFile(track)
        return true
    }

    func presentMissingFile(_ track: LoadedTrack) {
        let url = track.track.fileURL
        let name = track.track.title.isEmpty ? url.lastPathComponent : track.track.title
        NSApp.activate(ignoringOtherApps: true)

        // Whole drive offline: the files aren't gone, the drive is unplugged.
        // Offer only "OK" — never "Remove" — so we can't nuke an offline library.
        if let volume = offlineVolumeName(for: url) {
            let alert = NSAlert()
            alert.messageText = "“\(name)” is on a disconnected drive."
            alert.informativeText = "The drive “\(volume)” isn’t connected. Reconnect it and try again.\n\nLast known location:\n\(url.path)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Volume present but the file isn't where we left it: moved or deleted.
        let alert = NSAlert()
        alert.messageText = "Could not locate “\(describe(track)).”"
        alert.informativeText = "The file for this track could not be found. Last known location was \(url.path). Would you like to locate it?"
        alert.addButton(withTitle: "Locate…")            // .alertFirstButtonReturn
        alert.addButton(withTitle: "Remove From Library") // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")              // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            locateMissingFile(track)
        case .alertSecondButtonReturn:
            removeTrackFromLibrary(track)
        default:
            break
        }
    }

    private func describe(_ track: LoadedTrack) -> String {
        let t = track.track
        let name = t.title.isEmpty ? t.fileURL.lastPathComponent : t.title
        var parts = name
        if !t.artist.isEmpty { parts += " by \(t.artist)" }
        if !t.album.isEmpty { parts += " from \(t.album)" }
        return parts
    }

    /// The name of the `/Volumes/<name>` drive holding `url` when that drive is
    /// not currently mounted; `nil` if the volume is present (or the file lives
    /// on the boot volume, which is always mounted).
    func offlineVolumeName(for url: URL) -> String? {
        guard let volume = volumeName(of: url) else { return nil }
        return FileManager.default.fileExists(atPath: "/Volumes/\(volume)") ? nil : volume
    }

    private func locateMissingFile(_ track: LoadedTrack) {
        guard let newURL = promptForReplacementFile(track) else { return }
        reattach(track, to: newURL)
        playTrack(id: track.track.withFileURL(newURL).id)
    }

    /// Re-attach one missing track to a file the user located, without playing it.
    /// Used by the Missing Tracks maintenance panel.
    func relinkMissingTrack(_ track: LoadedTrack) {
        guard let newURL = promptForReplacementFile(track) else { return }
        reattach(track, to: newURL)
        recomputeMissingFiles()
        scanForCleanup()
    }

    private func promptForReplacementFile(_ track: LoadedTrack) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Locate “\(track.track.title.isEmpty ? track.track.fileURL.lastPathComponent : track.track.title)”"
        panel.prompt = "Locate"
        panel.directoryURL = track.track.fileURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Repoint one track's file URL through the staging area, every crate, and the
    /// active index.
    private func reattach(_ track: LoadedTrack, to newURL: URL) {
        let oldURL = track.track.fileURL
        let relocated = LoadedTrack(
            track: track.track.withFileURL(newURL),
            metadata: track.metadata,
            recordMarkers: track.recordMarkers
        )
        if let i = prepCrateTracks.firstIndex(where: { $0.track.fileURL.path == oldURL.path }) {
            prepCrateTracks[i] = relocated
        }
        updateTrackURLInIndex(oldURL: oldURL, newTrack: relocated)
    }

    private func removeTrackFromLibrary(_ track: LoadedTrack) {
        purgeTracksFromLibraryState(paths: [track.track.fileURL.standardizedFileURL.path])
    }

    /// Drop one missing track's reference from the library (Missing Tracks panel).
    func removeMissingTrack(_ track: LoadedTrack) {
        removeTrackFromLibrary(track)
        recomputeMissingFiles()
        scanForCleanup()
    }

    // MARK: - Batch re-attach (locate a moved folder)

    /// Prompt for a folder, then re-attach every missing track whose filename is
    /// found under it (recursively). One pick re-links a whole moved library.
    func relinkMissingTracksFromFolder(_ tracks: [LoadedTrack]) {
        let missing = tracks.filter {
            $0.track.fileURL.isFileURL
                && !FileManager.default.fileExists(atPath: $0.track.fileURL.path)
        }
        guard !missing.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Locate the folder these files moved to"
        panel.prompt = "Search Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let root = panel.url else { return }

        let missingURLs = missing.map { $0.track.fileURL }
        let byOldURL = Dictionary(missing.map { ($0.track.fileURL, $0) }, uniquingKeysWith: { a, _ in a })

        Task.detached { [weak self] in
            let candidates = Self.audioFiles(under: root)
            let mapping = RelinkMatcher.match(missing: missingURLs, candidates: candidates)
            var newTracks: [LoadedTrack] = []
            for (old, new) in mapping {
                guard let loaded = byOldURL[old] else { continue }
                newTracks.append(LoadedTrack(
                    track: loaded.track.withFileURL(new),
                    metadata: loaded.metadata,
                    recordMarkers: loaded.recordMarkers
                ))
            }
            // Explicit capture list: `self` (weak) and `newTracks` are mutable
            // vars in this scope; Swift 6 requires immutable captures in
            // concurrently-executing closures.
            await MainActor.run { [weak self, newTracks] in
                guard let self else { return }
                let matched = mapping.count
                if matched > 0 {
                    for track in newTracks {
                        if let i = self.prepCrateTracks.firstIndex(where: {
                            $0.track.id == track.track.id
                        }) { self.prepCrateTracks[i] = track }
                    }
                    self.updateTrackURLsInIndex(newTracks)
                    self.recomputeMissingFiles()
                    self.scanForCleanup()
                }
                self.appAlert = .error(
                    title: "Re-Attached",
                    message: "Re-linked \(matched) of \(missing.count) missing "
                        + "\(missing.count == 1 ? "file" : "files") found under “\(root.lastPathComponent).”"
                )
            }
        }
    }

    /// Recursively collect audio files under a folder for filename matching.
    private nonisolated static func audioFiles(under root: URL) -> [URL] {
        let exts: Set<String> = ["flac", "mp3", "m4a", "aac", "alac", "wav", "aiff", "aif", "ogg", "opus", "wma", "aifc"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where exts.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
        return result
    }

    // MARK: - Missing-file detection (browser badge)

    /// Recompute which library files are gone from disk while their drive is still
    /// mounted. Stats every local track off the main thread, then publishes the
    /// path set that drives `isMissing(_:)`. Cheap set lookups keep the browser
    /// stat-free at scroll time.
    func recomputeMissingFiles() {
        let tracks = localIndex.allTracks
        let offline = offlineVolumes
        Task.detached { [weak self] in
            var missing = Set<String>()
            for loaded in tracks {
                let url = loaded.track.fileURL
                guard url.isFileURL else { continue }
                // A file on an unplugged drive is "offline", not "missing".
                let components = url.standardizedFileURL.pathComponents
                if components.count >= 3, components[1] == "Volumes", offline.contains(components[2]) {
                    continue
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.insert(url.standardizedFileURL.path)
                }
            }
            await MainActor.run { [weak self, missing] in self?.missingTrackKeys = missing }
        }
    }

    /// Whether a track's file is missing from disk (drive present, file gone).
    func isMissing(_ track: LoadedTrack) -> Bool {
        guard !missingTrackKeys.isEmpty else { return false }   // fast path
        return missingTrackKeys.contains(track.track.fileURL.standardizedFileURL.path)
    }

    // MARK: - Offline volume tracking

    /// Subscribe to drive mount/unmount so the offline badge + the Sources
    /// "Devices" list update live.
    func setupVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.recomputeOfflineVolumes()
                    self?.recomputeMissingFiles()
                    self?.refreshCDs()
                    self?.refreshDevices()
                }
            }
        }
        // Adding/removing a device profile in Settings changes which mounted
        // volumes qualify as devices — re-filter immediately.
        NotificationCenter.default.addObserver(
            forName: PreferencesStore.deviceProfilesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    /// Recompute which `/Volumes/<name>` drives referenced by the local library
    /// are not currently mounted. Iterates the local index, so it's independent
    /// of the visible source; runs only on mount/unmount + at startup.
    func recomputeOfflineVolumes() {
        var referenced = Set<String>()
        for track in localIndex.allTracks {
            if let volume = volumeName(of: track.track.fileURL) {
                referenced.insert(volume)
            }
        }
        offlineVolumes = referenced.filter { !FileManager.default.fileExists(atPath: "/Volumes/\($0)") }
    }

    /// Whether a track's file lives on a drive that isn't currently mounted.
    func isOffline(_ track: LoadedTrack) -> Bool {
        guard !offlineVolumes.isEmpty else { return false }   // fast path: nothing offline
        guard let volume = volumeName(of: track.track.fileURL) else { return false }
        return offlineVolumes.contains(volume)
    }

    /// The `/Volumes/<name>` drive a file lives on, or `nil` for the boot volume.
    private func volumeName(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return components[2]
    }
}
