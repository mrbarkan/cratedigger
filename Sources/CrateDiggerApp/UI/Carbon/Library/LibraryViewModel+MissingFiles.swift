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
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        let volumeRoot = "/Volumes/\(components[2])"
        return FileManager.default.fileExists(atPath: volumeRoot) ? nil : components[2]
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
}
