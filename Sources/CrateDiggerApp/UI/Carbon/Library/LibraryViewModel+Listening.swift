import Foundation
import CrateDiggerCore

/// Listening history: the store, and reading from it. Recording lives further
/// down this file once Task 5 lands.
///
/// The store is cached per crates folder exactly like `TrackStore`, and for the
/// same reason: switching the crates index folder must give you that folder's
/// history, not the last one's.
@MainActor
extension LibraryViewModel {

    func currentListeningStore() -> ListeningStore {
        let folder = cratesDirectoryURL
        if let store = listeningStore, listeningStoreFolder?.path == folder.path {
            return store
        }
        let store = ListeningStore(fileURL: folder.appendingPathComponent("library.cdplays"))
        listeningStore = store
        listeningStoreFolder = folder
        return store
    }

    /// Persist, surfacing failures rather than dropping history while the UI
    /// claims nothing happened. Unlike the track store there is no rescan that
    /// can rebuild this, so a failure is worth an alert.
    @discardableResult
    func persistListeningStore() -> Bool {
        do {
            try currentListeningStore().save()
            return true
        } catch {
            AppLog.library.error("Failed to save listening history: \(error.localizedDescription)")
            appAlert = .error(
                title: "Listening History Not Saved",
                message: "Could not write your play counts and ratings: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// First run against a library that predates the plays file: give every
    /// known track a dateAdded so Phase 2's date rules have something to read.
    /// The date is the track index's own modification time, which is the closest
    /// thing to "when this library was last real" that exists on disk.
    func backfillListeningStoreIfNeeded(knownPaths: [String]) {
        let store = currentListeningStore()
        guard store.count == 0, !knownPaths.isEmpty else { return }
        let indexURL = cratesDirectoryURL.appendingPathComponent("library.cdtracks")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()
        store.backfill(paths: knownPaths, dateAdded: stamp)
        persistListeningStore()
        AppLog.library.notice("Backfilled listening history for \(knownPaths.count, privacy: .public) track(s)")
    }

    /// Called when the crates folder changes, so the next access rebuilds
    /// against the new folder.
    func resetListeningStoreCache() {
        listeningStore = nil
        listeningStoreFolder = nil
    }
}
