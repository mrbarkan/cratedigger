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
    ///
    /// Alerted once per store, then logged: the failure mode is permanent (an
    /// unreadable file never becomes writable mid-session) and this is called on
    /// every counted play and every skip, so alerting each time turned one
    /// corrupt file into a modal per track. The latch clears when the store is
    /// rebuilt in `resetListeningStoreCache()`.
    @discardableResult
    func persistListeningStore() -> Bool {
        do {
            try currentListeningStore().save()
            return true
        } catch {
            AppLog.library.error("Failed to save listening history: \(error.localizedDescription)")
            guard !listeningSaveFailureAlerted else { return false }
            listeningSaveFailureAlerted = true
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
        listeningSaveFailureAlerted = false
        markListeningSummaryStale()
    }

    /// Count a play once the same threshold that triggers a scrobble is met.
    ///
    /// Guarded by `countedPlayKey` rather than by the scrobble guard, because
    /// the two must not be coupled: a user with no Last.fm account still gets
    /// play counts, and the scrobble guard is cleared by network paths this has
    /// no business knowing about.
    ///
    /// Attributed via `listeningTrack`, not `nowPlayingTrack`: a time tick
    /// can land inside the window where a queue has been replaced but the index
    /// has not moved yet, and `nowPlayingTrack` names the wrong record there.
    func recordPlayIfThresholdMet(elapsed: Double, duration: Double) {
        guard !isRadioMode else { return }
        guard let playing = listeningTrack else { return }
        guard countedPlayKey != playing.key else { return }
        guard PlayThreshold.isPlayed(elapsed: elapsed, duration: duration) else { return }

        countedPlayKey = playing.key
        currentListeningStore().recordPlay(path: playing.key)
        // ponytail: saved on every counted play. At one write per several
        // minutes of listening that is nothing; if a shuffle-heavy session ever
        // shows up in a profile, batch it behind a timer.
        persistListeningStore()
        markListeningSummaryStale()
    }

    /// The track being left counts as skipped if it was abandoned part-way.
    /// Called from the index-change callback, before the per-track counters are
    /// reset for the incoming track.
    ///
    /// Reads `listeningTrack` rather than `nowPlayingTrack` for the reason
    /// that property documents: on a queue replacement `nowPlayingTrack` is
    /// already the new queue indexed by the old position, so deriving the
    /// outgoing track from it wrote the skip against an unrelated record.
    func recordSkipForOutgoingTrack() {
        guard !isRadioMode else { return }
        guard let outgoing = listeningTrack else { return }
        listeningTrack = nil
        guard countedPlayKey != outgoing.key else { return }
        // Nothing at all was heard: an auto-advance into a track that failed to
        // open is not a skip, it is a non-event.
        guard listenedSeconds > 0 else { return }
        // Hearing a short track out is not a skip, even though it can never
        // reach the play threshold — see PlayThreshold.isSkipped.
        guard PlayThreshold.isSkipped(elapsed: listenedSeconds, duration: outgoing.duration) else { return }

        currentListeningStore().recordSkip(path: outgoing.key)
        // ponytail: saved on every skip. Rapid skipping (holding next through a
        // folder) is higher-frequency than play counting; if a skip-heavy session
        // shows up in a profile, batch it behind a timer.
        persistListeningStore()
    }

    /// The rating shown for the current selection: the shared value when every
    /// selected track agrees, otherwise 0, because showing one track's three
    /// stars for a mixed selection would be a lie the user then overwrites.
    var ratingForSelection: Int {
        let tracks = resolvedSelectionTracks()
        guard let first = tracks.first else { return 0 }
        let store = currentListeningStore()
        let firstRating = store.stats(path: ListeningStore.key(for: first.track.fileURL))?.rating ?? 0
        for track in tracks.dropFirst() {
            let rating = store.stats(path: ListeningStore.key(for: track.track.fileURL))?.rating ?? 0
            if rating != firstRating { return 0 }
        }
        return firstRating
    }

    /// Whether there is a real selection to rate.
    ///
    /// `resolvedSelectionTracks()` falls back through `selectedTrack` to
    /// `visibleTracks.first`, which is right for its other callers (they all end
    /// in a sheet you can cancel) but not for rating: ⌘⌥3 is one keystroke and
    /// writes straight into a store with no undo and no backup, so it must not
    /// land on whatever happens to be top of the list, or on a stale local track
    /// while the user is browsing Radio.
    var hasRatableSelection: Bool {
        guard !isRadioMode else { return false }
        if selectedTrackIDs.count > 1 || selectedAlbumIDs.count > 1 || selectedArtistIDs.count > 1 {
            return true
        }
        return selectedTrackID != nil
    }

    /// Rate everything selected. 0 clears.
    func rateSelection(_ rating: Int) {
        guard hasRatableSelection else { return }
        let tracks = resolvedSelectionTracks()
        guard !tracks.isEmpty else { return }
        let store = currentListeningStore()
        for track in tracks {
            store.setRating(rating, path: ListeningStore.key(for: track.track.fileURL))
        }
        persistListeningStore()
        // A Rating column groups by what was just changed.
        if browserView.facets.contains(.rating) { recomputeSortedCollections() }
        objectWillChange.send()
        showOLEDNotice(rating == 0
                       ? "RATING CLEARED"
                       : "RATED \(rating) STAR\(rating == 1 ? "" : "S")")
    }
}
