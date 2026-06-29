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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Locate “\(track.track.title.isEmpty ? track.track.fileURL.lastPathComponent : track.track.title)”"
        panel.prompt = "Locate"
        panel.directoryURL = track.track.fileURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let newURL = panel.url else { return }

        let oldURL = track.track.fileURL
        let relocated = LoadedTrack(
            track: track.track.withFileURL(newURL),
            metadata: track.metadata,
            recordMarkers: track.recordMarkers
        )
        // Patch the staging area, then every crate + the active index.
        if let i = prepCrateTracks.firstIndex(where: { $0.track.fileURL.path == oldURL.path }) {
            prepCrateTracks[i] = relocated
        }
        updateTrackURLInIndex(oldURL: oldURL, newTrack: relocated)
        playTrack(id: relocated.track.id)
    }

    private func removeTrackFromLibrary(_ track: LoadedTrack) {
        purgeTracksFromLibraryState(paths: [track.track.fileURL.standardizedFileURL.path])
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
                    self?.refreshCDs()
                    self?.refreshDevices()
                }
            }
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
