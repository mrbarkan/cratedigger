import CrateDiggerCore
import Foundation

/// Up Next: queueing tracks behind whatever is playing, and editing that queue.
///
/// `playback.queue` (what the engine plays) and `playbackQueue` (the
/// `LoadedTrack`s the UI shows) are parallel arrays addressed by the same index.
/// Every mutation here changes both in the same step, because the moment they
/// disagree the Up Next list describes tracks other than the ones that will play.
@MainActor
extension LibraryViewModel {

    // MARK: - Reading

    /// Everything queued after the playing track, in play order.
    var upNextTracks: [LoadedTrack] {
        guard let current = playbackCurrentIndex, current >= 0 else { return playbackQueue }
        let start = min(current + 1, playbackQueue.count)
        return Array(playbackQueue[start...])
    }

    var hasUpNext: Bool { !upNextTracks.isEmpty }

    /// Queue actions only make sense for local files — a stream has no queue.
    var canQueueTracks: Bool { !isStreamActive }

    static func queueItem(for loaded: LoadedTrack) -> PlaybackQueueItem {
        PlaybackQueueItem(
            url: loaded.track.fileURL,
            title: loaded.track.title,
            artist: loaded.track.artist,
            album: loaded.track.album,
            durationSeconds: loaded.track.durationSeconds
        )
    }

    // MARK: - Queueing

    /// Insert directly after the playing track. With nothing playing yet this
    /// starts playback instead of silently filling an invisible queue.
    func playNext(_ tracks: [LoadedTrack]) {
        enqueue(tracks, next: true)
    }

    /// Append to the end of the queue.
    func playLast(_ tracks: [LoadedTrack]) {
        enqueue(tracks, next: false)
    }

    private func enqueue(_ tracks: [LoadedTrack], next: Bool) {
        let queueable = tracks.filter { !$0.track.fileURL.path.isEmpty }
        guard !queueable.isEmpty else { return }

        // A stream owns playback exclusively; queueing a file has to end it or
        // the queue would fill up behind something that never advances.
        if isStreamActive { stopRadio() }

        // Nothing playing: this is just "play these", so start them.
        guard playbackCurrentIndex != nil, !playbackQueue.isEmpty else {
            startQueue(queueable, at: 0)
            return
        }

        let range = next
            ? playback.insertNext(queueable.map(Self.queueItem))
            : playback.appendLast(queueable.map(Self.queueItem))
        playbackQueue.insert(contentsOf: queueable, at: min(range.lowerBound, playbackQueue.count))

        showOLEDNotice(queueNotice(count: queueable.count, next: next))
        savePlaybackSnapshot()
    }

    private func queueNotice(count: Int, next: Bool) -> String {
        let noun = count == 1 ? "TRACK" : "\(count) TRACKS"
        return next ? "\(noun) UP NEXT" : "\(noun) QUEUED"
    }

    /// Replace the queue outright and start playing at `index`.
    private func startQueue(_ tracks: [LoadedTrack], at index: Int) {
        guard !tracks.isEmpty else { return }
        if presentIfFileMissing(tracks[min(index, tracks.count - 1)]) { return }
        oledView = .nowPlaying
        playingSource = currentSource
        playbackQueue = tracks
        playback.load(queue: tracks.map(Self.queueItem), startIndex: index, autoPlay: true)
        savePlaybackSnapshot()
    }

    // MARK: - Editing

    /// Remove queued tracks by their id. The playing track is never removed.
    func removeFromQueue(trackIDs: Set<UUID>) {
        guard !trackIDs.isEmpty else { return }
        let offsets = IndexSet(
            playbackQueue.enumerated()
                .filter { trackIDs.contains($0.element.track.id) }
                .map(\.offset)
        )
        let removed = playback.removeFromQueue(at: offsets)
        guard !removed.isEmpty else { return }
        for index in removed.sorted(by: >) where playbackQueue.indices.contains(index) {
            playbackQueue.remove(at: index)
        }
        savePlaybackSnapshot()
    }

    /// Drop everything after the playing track, keeping it playing.
    func clearUpNext() {
        guard let current = playbackCurrentIndex, current >= 0 else {
            playbackQueue = []
            playback.load(queue: [], startIndex: 0, autoPlay: false)
            savePlaybackSnapshot()
            return
        }
        let tail = IndexSet(integersIn: min(current + 1, playbackQueue.count)..<playbackQueue.count)
        guard !tail.isEmpty else { return }
        playback.removeFromQueue(at: tail)
        playbackQueue.removeSubrange(min(current + 1, playbackQueue.count)..<playbackQueue.count)
        showOLEDNotice("QUEUE CLEARED")
        savePlaybackSnapshot()
    }

    /// Reorder a queued track. Indices address the full queue, not just Up Next.
    func moveInQueue(from source: Int, to destination: Int) {
        guard playbackQueue.indices.contains(source), source != playbackCurrentIndex else { return }
        playback.moveInQueue(from: source, to: destination)

        let clamped = min(max(destination, 0), playbackQueue.count)
        let item = playbackQueue.remove(at: source)
        let target = min(clamped > source ? clamped - 1 : clamped, playbackQueue.count)
        playbackQueue.insert(item, at: target)
        savePlaybackSnapshot()
    }

    /// Jump straight to a queued track (double-clicking a row in Up Next).
    func playFromQueue(trackID: UUID) {
        guard let index = playbackQueue.firstIndex(where: { $0.track.id == trackID }) else { return }
        if presentIfFileMissing(playbackQueue[index]) { return }
        oledView = .nowPlaying
        playback.load(queue: playbackQueue.map(Self.queueItem), startIndex: index, autoPlay: true)
        savePlaybackSnapshot()
    }

    /// The tracks a browser selection means, for the queue actions in the
    /// context menu: the multi-selection when the clicked row is part of it,
    /// otherwise just what was clicked.
    func queueTargets(forClicked tracks: [LoadedTrack]) -> [LoadedTrack] {
        let selected = selectedTracksForCrateAdd()
        let clickedIDs = Set(tracks.map { $0.track.id })
        let isPartOfSelection = selected.count > 1 && clickedIDs.contains { id in
            selected.contains { $0.track.id == id }
        }
        return isPartOfSelection ? selected : tracks
    }
}
