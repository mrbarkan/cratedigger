import CrateDiggerCore
import Foundation

/// An editable row in the Record Divider review sheet. Detection seeds one row per
/// candidate track; the user keeps/skips, renames, and nudges/merges/splits them.
/// On apply, the kept rows become the track's `[RecordMarker]`.
struct RecordDividerDraftRow: Identifiable, Hashable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var title: String
    var keep: Bool

    init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, title: String, keep: Bool = true) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
        self.keep = keep
    }

    init(marker: RecordMarker, keep: Bool = true) {
        self.init(startSeconds: marker.startSeconds, endSeconds: marker.endSeconds, title: marker.title, keep: keep)
    }

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// Record Divider behaviour: launch a scan, review/edit the detected tracks, and
/// persist the result as `recordMarkers` on the `LoadedTrack`. Detection lives in
/// the Core `RecordDividerService`; splitting on export lives in the conversion
/// planner. This extension is the UI wiring between them.
@MainActor
extension LibraryViewModel {

    // MARK: - Entry

    /// Whether Record Divider can run on `track` (ffmpeg present + known duration).
    func canRecordDivide(_ track: LoadedTrack) -> Bool {
        track.track.durationSeconds > 0 && resolvedFfmpegURL() != nil
    }

    /// Open the review sheet for `track` and kick off the first scan.
    func beginRecordDivider(for track: LoadedTrack) {
        guard let ffmpeg = resolvedFfmpegURL() else {
            appAlert = .error(
                title: "ffmpeg Required",
                message: "Record Divider needs ffmpeg to scan for tracks. Install it (e.g. `brew install ffmpeg`) or set its path in Settings."
            )
            return
        }
        guard track.track.durationSeconds > 0 else {
            appAlert = .error(title: "Unknown Length",
                              message: "CrateDigger couldn't read this file's duration, so it can't scan for tracks.")
            return
        }
        recordDividerTrack = track
        recordDividerRows = (track.recordMarkers ?? []).map { RecordDividerDraftRow(marker: $0) }
        recordDividerSensitivity = 0.4
        recordDividerHint = nil
        showingRecordDividerSheet = true
        runRecordDividerScan(ffmpeg: ffmpeg, track: track)
    }

    /// The ffmpeg binary to use (custom Settings path overrides the PATH search).
    func resolvedFfmpegURL() -> URL? {
        let override = prefs.customFFmpegPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return ExternalToolLocator().resolveOptional(.ffmpeg, explicitOverride: override)?.url
    }

    // MARK: - Scanning

    /// Re-detect with the current sensitivity, replacing the rows. Boundaries (and
    /// therefore titles) reset — manual edits are discarded.
    func rescanRecordDivider() {
        guard let track = recordDividerTrack, let ffmpeg = resolvedFfmpegURL() else { return }
        runRecordDividerScan(ffmpeg: ffmpeg, track: track)
    }

    private func runRecordDividerScan(ffmpeg: URL, track: LoadedTrack) {
        recordDividerIsScanning = true
        recordDividerHint = nil
        let sensitivity = RecordDetectionSensitivity.fromSlider(recordDividerSensitivity)
        let url = track.track.fileURL
        let duration = track.track.durationSeconds

        Task { [weak self] in
            let outcome: Result<[RecordMarker], Error> = await Task.detached {
                do {
                    let service = RecordDividerService(ffmpegURL: ffmpeg)
                    return .success(try service.detect(fileURL: url, totalDuration: duration, sensitivity: sensitivity))
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                guard let self, self.recordDividerTrack?.track.id == track.track.id else { return }
                self.recordDividerIsScanning = false
                switch outcome {
                case .success(let markers):
                    self.recordDividerRows = markers.map { RecordDividerDraftRow(marker: $0) }
                    if markers.count <= 1 {
                        self.recordDividerHint = "No track breaks detected — drag sensitivity up and re-scan."
                    }
                case .failure(let error):
                    self.recordDividerHint = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Row editing

    private func rowIndex(_ id: UUID) -> Int? {
        recordDividerRows.firstIndex { $0.id == id }
    }

    func recordDividerToggleKeep(_ id: UUID) {
        guard let i = rowIndex(id) else { return }
        recordDividerRows[i].keep.toggle()
    }

    func recordDividerRename(_ id: UUID, to title: String) {
        guard let i = rowIndex(id) else { return }
        recordDividerRows[i].title = title
    }

    /// Nudge a boundary. `isStart` moves the row's start (and the previous row's
    /// end); otherwise its end (and the next row's start). Boundaries stay ordered.
    func recordDividerNudge(_ id: UUID, isStart: Bool, by delta: Double) {
        guard let i = rowIndex(id) else { return }
        if isStart {
            let lower = i > 0 ? recordDividerRows[i - 1].startSeconds + 1 : 0
            let upper = recordDividerRows[i].endSeconds - 1
            let value = min(max(recordDividerRows[i].startSeconds + delta, lower), upper)
            recordDividerRows[i].startSeconds = value
            if i > 0 { recordDividerRows[i - 1].endSeconds = value }
        } else {
            let next = i < recordDividerRows.count - 1 ? recordDividerRows[i + 1].endSeconds - 1 : .greatestFiniteMagnitude
            let lower = recordDividerRows[i].startSeconds + 1
            let value = min(max(recordDividerRows[i].endSeconds + delta, lower), next)
            recordDividerRows[i].endSeconds = value
            if i < recordDividerRows.count - 1 { recordDividerRows[i + 1].startSeconds = value }
        }
    }

    /// Merge a row into the following one (removes the boundary between them). The
    /// merged row keeps this row's title.
    func recordDividerMergeWithNext(_ id: UUID) {
        guard let i = rowIndex(id), i < recordDividerRows.count - 1 else { return }
        recordDividerRows[i].endSeconds = recordDividerRows[i + 1].endSeconds
        recordDividerRows.remove(at: i + 1)
    }

    /// Split a row at its midpoint, inserting a new boundary (then nudge to taste).
    func recordDividerSplit(_ id: UUID) {
        guard let i = rowIndex(id) else { return }
        let row = recordDividerRows[i]
        guard row.durationSeconds > 2 else { return }
        let mid = (row.startSeconds + row.endSeconds) / 2
        recordDividerRows[i].endSeconds = mid
        let newRow = RecordDividerDraftRow(startSeconds: mid, endSeconds: row.endSeconds,
                                           title: "\(row.title) (2)", keep: row.keep)
        recordDividerRows.insert(newRow, at: i + 1)
    }

    // MARK: - Apply / cancel

    /// Persist the kept rows as the track's markers and close the sheet. With no
    /// kept rows, clears markers (the track becomes undivided again).
    func applyRecordDivider() {
        guard let track = recordDividerTrack else { return }
        let kept = recordDividerRows
            .filter { $0.keep && $0.durationSeconds > 0 }
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { RecordMarker(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, title: $0.title) }
        persistRecordMarkers(kept.isEmpty ? nil : kept, for: track)
        closeRecordDivider()
    }

    func cancelRecordDivider() {
        closeRecordDivider()
    }

    /// Remove a track's markers (from the context menu) without opening the sheet.
    func clearRecordMarkers(for track: LoadedTrack) {
        persistRecordMarkers(nil, for: track)
    }

    // MARK: - Playback navigation (divided tracks)

    /// Markers of the file currently playing, if it's a divided record.
    var nowPlayingRecordMarkers: [RecordMarker] {
        nowPlayingTrack?.recordMarkers ?? []
    }

    /// Index of the Record Divider track playing right now (by playhead position),
    /// or `nil` when the now-playing file isn't divided.
    var currentRecordTrackIndex: Int? {
        guard !nowPlayingRecordMarkers.isEmpty else { return nil }
        return nowPlayingTrack?.recordTrackIndex(at: playbackCurrentTime)
    }

    var currentRecordTrack: RecordMarker? {
        guard let i = currentRecordTrackIndex, nowPlayingRecordMarkers.indices.contains(i) else { return nil }
        return nowPlayingRecordMarkers[i]
    }

    /// Seek to the next marker's start; returns false at the last marker (so the
    /// caller advances to the next file instead).
    func recordSeekToNextTrack() -> Bool {
        let markers = nowPlayingRecordMarkers
        guard let i = currentRecordTrackIndex, i + 1 < markers.count else { return false }
        playback.seek(toSeconds: markers[i + 1].startSeconds)
        return true
    }

    /// Play a divided record from a specific marker (double-clicking a sub-track in
    /// the browser). Seeks immediately if the file is already current; otherwise
    /// starts it and defers the seek until playback is running.
    func playRecordTrack(parent: LoadedTrack, markerIndex: Int) {
        guard let markers = parent.recordMarkers, markers.indices.contains(markerIndex) else { return }
        let start = markers[markerIndex].startSeconds
        selectedTrackID = parent.track.id

        if nowPlayingTrack?.track.id == parent.track.id,
           playbackState == .playing || playbackState == .paused {
            playback.seek(toSeconds: start)
            if playbackState == .paused { playback.play() }
            return
        }
        pendingRecordSeekTrackID = parent.track.id
        pendingRecordSeekSeconds = start
        playTrack(id: parent.track.id)
    }

    /// Apply a deferred marker seek once the target file is actually playing (its
    /// duration is known). Called from the playback time binding.
    func applyPendingRecordSeekIfNeeded() {
        guard let seconds = pendingRecordSeekSeconds,
              let id = pendingRecordSeekTrackID,
              nowPlayingTrack?.track.id == id,
              playbackDuration > 0 else { return }
        pendingRecordSeekTrackID = nil
        pendingRecordSeekSeconds = nil
        playback.seek(toSeconds: seconds)
    }

    /// Previous-track behaviour within a divided file: restart the current track if
    /// we're more than `restartThreshold` into it, else jump to the previous
    /// marker. Returns false at the very start of the first marker.
    func recordSeekToPreviousTrack(restartThreshold: Double = 3) -> Bool {
        let markers = nowPlayingRecordMarkers
        guard let i = currentRecordTrackIndex, markers.indices.contains(i) else { return false }
        if playbackCurrentTime - markers[i].startSeconds > restartThreshold {
            playback.seek(toSeconds: markers[i].startSeconds)
            return true
        }
        if i > 0 {
            playback.seek(toSeconds: markers[i - 1].startSeconds)
            return true
        }
        return false
    }

    private func closeRecordDivider() {
        showingRecordDividerSheet = false
        recordDividerTrack = nil
        recordDividerRows = []
        recordDividerHint = nil
        recordDividerIsScanning = false
    }

    // MARK: - Persistence

    /// Write updated markers onto the track everywhere it lives — the in-memory
    /// Prep Crate and every `.cdlib` crate that references the file (matched by
    /// path, which markers don't change) — then refresh the active view.
    private func persistRecordMarkers(_ markers: [RecordMarker]?, for track: LoadedTrack) {
        let updated = LoadedTrack(track: track.track, metadata: track.metadata, recordMarkers: markers)
        let path = track.track.fileURL.path

        if let i = prepCrateTracks.firstIndex(where: { $0.track.fileURL.path == path }) {
            prepCrateTracks[i] = updated
        }

        for crateName in availableCrates {
            var tracks = loadCrateTracks(name: crateName)
            var modified = false
            for i in tracks.indices where tracks[i].track.fileURL.path == path {
                tracks[i] = updated
                modified = true
            }
            if modified { saveCrateTracks(tracks, name: crateName) }
        }

        selectSource(currentSource)
    }
}
