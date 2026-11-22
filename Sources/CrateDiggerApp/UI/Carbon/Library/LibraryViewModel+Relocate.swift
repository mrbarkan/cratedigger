import AppKit
import CrateDiggerCore
import Foundation

/// Relocate Library: the music was copied or moved to another folder outside
/// the app, and every crate still names the old paths.
///
/// Move Music Files moves the files itself and needs none of this. The Missing
/// Tracks panel re-links only files that are gone while their drive is
/// connected, so a library that was *copied* (the old files still there, or
/// their drive unplugged) had no way in. Here the owner picks the folder the
/// copy is in, Core's `LibraryRelocation` works out which tracks have a copy at
/// their own place inside it, and after one confirmation the crates are
/// rewritten through `updateTrackURLsInIndex`, the same funnel Move Music Files
/// uses, so play counts, ratings and downloads follow. No file is touched.
extension LibraryViewModel {

    func relocateLibrary() {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard !isRelocatingLibrary else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose the folder your music was copied to"
        panel.message = "Choose the folder that now holds your music. Nothing is moved or deleted."
        panel.prompt = "Relocate"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let newRoot = panel.url else { return }

        Task { await relocateLibrary(to: newRoot, confirm: Self.askToRelocate) }
    }

    /// The whole action after the folder is chosen. `confirm` is the question
    /// asked before anything is changed; the DEBUG check answers it itself.
    func relocateLibrary(to newRoot: URL, confirm: (LibraryRelocation.Plan) -> Bool) async {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard !isRelocatingLibrary else { return }
        isRelocatingLibrary = true
        let activity = beginActivity("Looking for your library in \(newRoot.lastPathComponent)…")
        let trackURLs = Array(Set(relocatableTracks().map { $0.track.fileURL }))

        let outcome = await Task.detached(priority: .userInitiated) {
            // Only the kinds of file the library holds: a whole drive can be
            // picked, and nothing else on it could be a track's copy.
            let extensions = Set(trackURLs.map { $0.pathExtension.lowercased() })
            let candidates = Self.files(under: newRoot, withExtensions: extensions)
            return LibraryRelocation.plan(tracks: trackURLs, newRoot: newRoot, candidates: candidates)
        }.value
        endActivity(activity)
        isRelocatingLibrary = false

        switch outcome {
        case .noCopyFound:
            let text = LibraryRelocationText.noCopyFound(in: newRoot)
            appAlert = .error(title: text.title, message: text.message)
        case .alreadyThere:
            let text = LibraryRelocationText.alreadyThere(in: newRoot)
            appAlert = .error(title: text.title, message: text.message)
        case .relocate(let plan):
            guard confirm(plan) else { return }
            applyRelocation(plan)
        }
    }

    /// App-modal, as the other library questions are: the button is in the
    /// Preferences window, where an alert on the main window would sit behind.
    private static func askToRelocate(_ plan: LibraryRelocation.Plan) -> Bool {
        let text = LibraryRelocationText.confirmation(plan)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: "Relocate")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Every local track a relocation can move: the shared store behind the
    /// crates, and the staging area, which holds tracks no crate has yet.
    private func relocatableTracks() -> [LoadedTrack] {
        var seen = Set<UUID>()
        return (currentTrackStore().allTracks + prepCrateTracks).filter {
            $0.track.fileURL.isFileURL && seen.insert($0.track.id).inserted
        }
    }

    private func applyRelocation(_ plan: LibraryRelocation.Plan) {
        // Asked again: the drive holding the index can have gone while the
        // folder was being read or the question was on screen.
        guard !refuseWhileLibraryDisconnected() else { return }

        // Read again rather than carried from before the folder walk, so a
        // track retagged or filed meanwhile is rewritten as it is now.
        let relocated = relocatableTracks().compactMap { loaded -> LoadedTrack? in
            guard let newURL = plan.moves[loaded.track.fileURL] else { return nil }
            return LoadedTrack(
                track: loaded.track.withFileURL(newURL),
                metadata: loaded.metadata,
                recordMarkers: loaded.recordMarkers
            )
        }
        guard !relocated.isEmpty else {
            let text = LibraryRelocationText.alreadyThere(in: plan.newRoot)
            appAlert = .error(title: text.title, message: text.message)
            return
        }

        // Crates first, as Move Music Files does: a bookmark that cannot be
        // made below must not leave the crates half way.
        updateTrackURLsInIndex(relocated)
        recomputeOfflineVolumes()
        recomputeMissingFiles()

        let musicFolderFollowed = repointMusicFolder(for: plan)
        let text = LibraryRelocationText.summary(
            plan,
            relocated: relocated.count,
            musicFolderFollowed: musicFolderFollowed,
            driveStillHoldingIndex: LibraryRelocation.driveStillHoldingIndex(
                indexFolder: cratesDirectoryURL, oldRoot: plan.oldRoot, newRoot: plan.newRoot)
        )
        AppLog.library.notice(
            "Relocated \(relocated.count) tracks; \(plan.withoutCopy) without a copy, \(plan.alreadyInLibrary) already in the library")
        appAlert = .error(title: text.title, message: text.message)
    }

    /// The Music Folder goes with the tracks when it was the old root or inside
    /// it and its place in the new folder exists. One set elsewhere is the
    /// owner's own choice and stays.
    private func repointMusicFolder(for plan: LibraryRelocation.Plan) -> Bool {
        guard let current = managedLibraryFolderURL,
              let target = LibraryRelocation.counterpart(of: current, from: plan.oldRoot, to: plan.newRoot)
        else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        do {
            prefs.managedLibraryFolderBookmark = try PreferencesStore.makeBookmark(for: target)
        } catch {
            AppLog.library.error("Relocate: the Music Folder bookmark could not be made")
            return false
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("CrateDiggerLibraryFolderChanged"), object: target)
        return true
    }

    /// Every visible regular file under a folder with one of the extensions.
    private nonisolated static func files(under root: URL, withExtensions extensions: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
        return result
    }
}
