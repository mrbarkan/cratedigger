import CrateDiggerCore
import Foundation

/// Resume where you left off: the transport is snapshotted as it changes and
/// put back, paused, at the next launch. The decidable part (what survives a
/// library that has moved on) is `PlaybackSnapshot.resolve`; this file is
/// the wiring.
@MainActor
extension LibraryViewModel {

    // MARK: - Deferred seek

    /// Apply a deferred seek once the target file is loaded and its duration
    /// is known. Called from the playback time binding. A paused load fires
    /// that tick too (`PlaybackService` sets the duration in `onItemReady`
    /// before deciding whether to play), which is what lets resume land on a
    /// position without ever starting playback.
    func applyPendingSeekIfNeeded() {
        guard let seconds = pendingSeekSeconds,
              let id = pendingSeekTrackID,
              nowPlayingTrack?.track.id == id,
              playbackDuration > 0 else { return }
        pendingSeekTrackID = nil
        pendingSeekSeconds = nil
        playback.seek(toSeconds: seconds)
    }

    // MARK: - Snapshot

    /// Sources whose tracks live in the track store and are still there at
    /// the next launch. A CD leaves with the disc, a remote queue with the
    /// session, a device with the cable.
    static func isResumable(_ source: LibrarySource?) -> Bool {
        switch source {
        case .localAll?, .localCrate?, .prepCrate?, .playlist?, nil:
            return true
        case .remote?, .cd?, .device?, .offlineDevice?, .radio?:
            return false
        }
    }

    /// Record the transport. Called on every index change, pause, end, queue
    /// edit that does not reload the queue, and at quit; cheap because
    /// identical bytes are not written twice. Loading a queue is deliberately
    /// not a caller: the index change the load fires is the save, and calling
    /// straight after `playback.load` would record the outgoing index.
    func savePlaybackSnapshot() {
        // A deferred seek is still outstanding for this track (resume at
        // launch, or a Record Divider sub-track): the position is not yet
        // real, and writing it would overwrite the snapshot that was just
        // read with 0:00. The seek's own pause or index change saves it.
        if let pending = pendingSeekTrackID, pending == nowPlayingTrack?.track.id { return }

        guard !isStreamActive,
              let index = playbackCurrentIndex,
              !playbackQueue.isEmpty,
              Self.isResumable(playingSource),
              let snapshot = PlaybackSnapshot(
                paths: playbackQueue.map { ListeningStore.key(for: $0.track.fileURL) },
                currentIndex: index,
                // A queue that ran dry parks the clock at the duration; coming
                // back to the last track at its final second is not a resume.
                positionSeconds: playbackState == .ended ? 0 : playback.currentTimeSeconds,
                sourceKey: (playingSource ?? .localAll).persistenceKey
              )
        else {
            clearPlaybackSnapshot()
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot) else { return }
        guard data != lastSavedPlaybackSnapshot else { return }
        lastSavedPlaybackSnapshot = data
        prefs.playbackSnapshotData = data
    }

    private func clearPlaybackSnapshot() {
        guard lastSavedPlaybackSnapshot != nil || prefs.playbackSnapshotData != nil else { return }
        lastSavedPlaybackSnapshot = nil
        prefs.playbackSnapshotData = nil
    }

    /// Put the last transport back, paused, at launch. Nothing is restored if
    /// the loaded track has left the library or its file is not on disk, and
    /// nothing is said about it: a missing file at launch is not something the
    /// user just did.
    func restorePlaybackSnapshot() {
        guard let data = prefs.playbackSnapshotData else { return }
        guard let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            clearPlaybackSnapshot()
            return
        }
        let store = currentTrackStore()
        guard let resolved = snapshot.resolve(
            track: { store.track(path: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            clearPlaybackSnapshot()
            return
        }

        // `persistenceKey` has no inverse and does not need one: match by key,
        // else All Records. A playlist is saved but not listed here, so it
        // comes back as All Records; the queue itself is intact and plays, only
        // the sidebar's playing mark moves, which is not worth a playlist load
        // at launch to avoid.
        let candidates: [LibrarySource] = [.localAll, .prepCrate]
            + availableCrates.map { LibrarySource.localCrate(name: $0) }
        playingSource = candidates.first { $0.persistenceKey == resolved.sourceKey } ?? .localAll

        playbackQueue = resolved.tracks
        if resolved.positionSeconds > 0 {
            pendingSeekTrackID = resolved.tracks[resolved.currentIndex].track.id
            pendingSeekSeconds = resolved.positionSeconds
        }
        lastSavedPlaybackSnapshot = data
        playback.load(queue: resolved.tracks.map(Self.queueItem), startIndex: resolved.currentIndex, autoPlay: false)
        AppLog.library.notice("Restored playback: \(resolved.tracks.count, privacy: .public) track(s) at \(Int(resolved.positionSeconds), privacy: .public)s")
    }
}
