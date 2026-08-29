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

    /// Count a play once the same threshold that triggers a scrobble is met.
    ///
    /// Guarded by `countedPlayTrackID` rather than by the scrobble guard,
    /// because the two must not be coupled: a user with no Last.fm account still
    /// gets play counts, and the scrobble guard is cleared by network paths this
    /// has no business knowing about.
    func recordPlayIfThresholdMet(elapsed: Double, duration: Double) {
        guard !isRadioMode else { return }
        guard let nowPlaying = nowPlayingTrack else { return }
        guard countedPlayTrackID != nowPlaying.track.id else { return }
        guard PlayThreshold.isPlayed(elapsed: elapsed, duration: duration) else { return }

        countedPlayTrackID = nowPlaying.track.id
        currentListeningStore().recordPlay(path: ListeningStore.key(for: nowPlaying.track.fileURL))
        // ponytail: saved on every counted play. At one write per several
        // minutes of listening that is nothing; if a shuffle-heavy session ever
        // shows up in a profile, batch it behind a timer.
        persistListeningStore()
    }

    /// The track being left counts as skipped if it never reached the play
    /// threshold. Called from the index-change callback, before the per-track
    /// counters are reset for the incoming track.
    func recordSkipForOutgoingTrack() {
        guard !isRadioMode else { return }
        guard let outgoing = nowPlayingTrack else { return }
        guard countedPlayTrackID != outgoing.track.id else { return }
        // Nothing at all was heard: an auto-advance into a track that failed to
        // open is not a skip, it is a non-event.
        guard listenedSeconds > 0 else { return }

        currentListeningStore().recordSkip(path: ListeningStore.key(for: outgoing.track.fileURL))
        persistListeningStore()
    }

    /// The rating shown for the current selection: the shared value when every
    /// selected track agrees, otherwise 0, because showing one track's three
    /// stars for a mixed selection would be a lie the user then overwrites.
    var ratingForSelection: Int {
        let tracks = tracksToRate()
        guard let first = tracks.first else { return 0 }
        let store = currentListeningStore()
        let firstRating = store.stats(path: ListeningStore.key(for: first.track.fileURL))?.rating ?? 0
        for track in tracks.dropFirst() {
            let rating = store.stats(path: ListeningStore.key(for: track.track.fileURL))?.rating ?? 0
            if rating != firstRating { return 0 }
        }
        return firstRating
    }

    /// Rate everything selected. 0 clears.
    func rateSelection(_ rating: Int) {
        let tracks = tracksToRate()
        guard !tracks.isEmpty else { return }
        let store = currentListeningStore()
        for track in tracks {
            store.setRating(rating, path: ListeningStore.key(for: track.track.fileURL))
        }
        persistListeningStore()
        objectWillChange.send()
        showOLEDNotice(rating == 0
                       ? "RATING CLEARED"
                       : "RATED \(rating) STAR\(rating == 1 ? "" : "S")")
    }

    /// A real multi-selection rates all of it; otherwise the anchor track.
    /// Mirrors `tracksForInspectorTagEdit()` so rating and tag editing never
    /// disagree about what "the selection" means.
    private func tracksToRate() -> [LoadedTrack] {
        if selectedTrackIDs.count > 1 || selectedAlbumIDs.count > 1 || selectedArtistIDs.count > 1 {
            return selectedTracksForCrateAdd()
        }
        return selectedTrack.map { [$0] } ?? []
    }
}
