import AppKit
import CrateDiggerCore
import Foundation

/// A library whose index lives on an external drive, while that drive is out.
///
/// Resolving the crates folder bookmark for an unplugged drive used to fail
/// into an empty folder in Application Support, where a fresh Personal Crate
/// was then written: the library looked gone, and anything saved that session
/// went into a stand-in. `LibraryLocation` now makes that call, and a
/// disconnected library loads read-only from `LibraryIndexCopy`, which is
/// refreshed at launch, at quit and when the drive is about to eject.
/// Design: docs/superpowers/specs/2026-09-16-offline-library-design.md.
@MainActor
extension LibraryViewModel {

    // MARK: - Where the library is

    func resolveLibraryLocation() -> LibraryLocation {
        #if DEBUG
        if let dir = Self.debugCratesDirectory { return .available(dir) }
        #endif
        let bookmark = prefs.cratesIndexFolderBookmark
        return LibraryLocation.resolve(
            bookmarkChosen: bookmark != nil,
            resolvedFolder: bookmark.flatMap { PreferencesStore.resolveBookmark($0)?.url },
            lastKnownFolder: libraryIndexCopy.record()?.sourceFolder,
            isVolumeMounted: Self.isVolumeMounted
        )
    }

    /// `/Volumes` is root-owned, so nothing a user process does can leave a
    /// folder of this name behind: it exists exactly while the drive is mounted.
    nonisolated static func isVolumeMounted(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Volumes/\(name)")
    }

    var isLibraryDisconnected: Bool { libraryLocation.isDisconnected }

    /// The unplugged drive's name, nil when connected or when nobody knows.
    var disconnectedLibraryVolumeName: String? {
        if case .disconnected(let name, _) = libraryLocation { return name }
        return nil
    }

    /// Stop an action that would change the library while its index is out of
    /// reach. Every such action calls this first; the index writers call it as
    /// well, as a backstop. Returns true when the action was refused.
    @discardableResult
    func refuseWhileLibraryDisconnected() -> Bool {
        guard case .disconnected(let volume, _) = libraryLocation else { return false }
        showOLEDNotice(volume.map { "\($0.uppercased()) IS DISCONNECTED" } ?? "LIBRARY FOLDER NOT FOUND")
        AppLog.library.notice("Refused a library change: the index is disconnected")
        return true
    }

    // MARK: - Keeping the copy

    /// The live index folder when it sits on an external drive that is mounted,
    /// which is the only time a copy is worth taking.
    private var externalLibraryFolder: URL? {
        #if DEBUG
        // A demo library in a debug run must never overwrite the real copy.
        if Self.debugCratesDirectory != nil { return nil }
        #endif
        guard case .available(let folder) = libraryLocation,
              LibraryLocation.volumeName(of: folder) != nil else { return nil }
        return folder
    }

    /// At launch and on reconnect: a few megabytes, off the main thread.
    func refreshLibraryIndexCopyInBackground() {
        guard let source = externalLibraryFolder else { return }
        let copy = libraryIndexCopy
        Task.detached(priority: .utility) {
            Self.writeLibraryIndexCopy(copy, from: source)
        }
    }

    /// At quit, where a detached task would never get to run.
    func refreshLibraryIndexCopyNow() {
        guard let source = externalLibraryFolder else { return }
        Self.writeLibraryIndexCopy(libraryIndexCopy, from: source)
    }

    nonisolated static func writeLibraryIndexCopy(_ copy: LibraryIndexCopy, from source: URL) {
        do {
            try copy.write(from: source)
            AppLog.library.notice("Copied the library index from \(source.path, privacy: .public)")
        } catch {
            // The previous copy is untouched by a failed write, so this costs
            // freshness, never the copy itself.
            AppLog.library.error("Could not copy the library index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The drive holding the index is about to eject: copy it while it can
    /// still be read. Called synchronously from the notification, because a
    /// hop to the main actor could run after the drive is gone.
    nonisolated static func copyLibraryIndexBeforeUnmount(volumeURL: URL?, copy: LibraryIndexCopy) {
        #if DEBUG
        if debugCratesDirectory != nil { return }
        #endif
        guard let volumePath = volumeURL?.standardizedFileURL.path,
              let bookmark = PreferencesStore.shared.cratesIndexFolderBookmark,
              let folder = PreferencesStore.resolveBookmark(bookmark)?.url,
              folder.standardizedFileURL.path.hasPrefix(volumePath + "/")
        else { return }
        writeLibraryIndexCopy(copy, from: folder)
    }

    // MARK: - Drives coming and going

    /// Re-decide where the library is after a mount, unmount or rename, and
    /// switch between the live folder and the copy when that changed.
    func libraryVolumesChanged() {
        let wasDisconnected = libraryLocation.isDisconnected
        guard resolveLibraryLocation() != libraryLocation else { return }

        refreshAvailableCrates()   // adopts the new location and reloads the crate list
        if case .localCrate(let name) = currentSource, !availableCrates.contains(name) {
            selectSource(.localAll)
        } else if isLocalSource {
            selectSource(currentSource)
        }
        if wasDisconnected, !libraryLocation.isDisconnected {
            AppLog.library.notice("Library drive reconnected; using the live index again")
            refreshLibraryIndexCopyInBackground()
        } else if libraryLocation.isDisconnected {
            AppLog.library.notice("Library drive disconnected; showing the local copy")
        }
    }
}
