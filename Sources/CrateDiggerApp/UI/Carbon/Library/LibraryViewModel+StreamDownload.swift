import AppKit
import CrateDiggerCore
import Foundation

/// A downloaded stream waiting for its scan: the markers and tag defaults the
/// scanner cannot know, and the stream to link the file back to. `queuedAt`
/// bounds how long an entry can wait — see `prunePendingStreamImports()`.
struct PendingStreamImport {
    let streamID: String
    let markers: [RecordMarker]
    let artist: String
    let album: String
    let queuedAt: Date = Date()
}

/// Download for Offline: yt-dlp saves a stream's audio into the library, it
/// lands in the Prep Crate like any dig, and its chapters arrive as Record
/// Divider markers. yt-dlp is bring-your-own, as for playback.
@MainActor
extension LibraryViewModel {
    var isDownloadingStream: Bool { downloadingStreamID != nil }

    /// Live never ends and a playlist is many downloads.
    func canDownload(_ stream: StreamSource) -> Bool {
        (stream.kind == .video || stream.kind == .mix) && !stream.isDownloaded()
    }

    func downloadStream(id: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard let stream = streams.first(where: { $0.id == id }), canDownload(stream) else { return }
        guard !isDownloadingStream else { return showOLEDNotice("ONE DOWNLOAD AT A TIME") }
        guard let root = currentConversionDestinationURL ?? managedLibraryFolderURL else {
            appAlert = .error(title: "No Destination Set",
                              message: "Configure a default output folder in Preferences first.")
            return
        }
        guard confirmPersonalUse() else { return }

        let plan: StreamDownloadPlan
        do { plan = try StreamDownloader.plan(for: stream, in: root) }
        catch { return appAlert = .error(title: "Can't Download", message: "Only single videos and mixes can be downloaded.") }
        guard !FileManager.default.fileExists(atPath: plan.fileURL.path) else {
            // Already on disk from an earlier run: adopt it instead of fetching
            // again. Nothing here downloads, so yt-dlp is not required.
            return finishStreamDownload(stream, fileURL: plan.fileURL)
        }

        guard let ytdlp = resolvedYtDlpURL() else {
            appAlert = .error(title: "yt-dlp Not Found",
                              message: "Downloading needs yt-dlp. Install it (for example with Homebrew: brew install yt-dlp) or set its path in Settings.")
            return
        }

        // A stream added but never opened has no chapters cached yet. Ask now;
        // `finishStreamDownload` reads the stream again when the file is ready.
        if stream.chapters == nil { fetchMetadata(for: id) }

        downloadingStreamID = id
        oledView = .cdRip
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 100,
                                                        currentFilename: stream.title, isRunning: true)
        let ffmpeg = ExternalToolLocator().resolveOptional(.ffmpeg)?.url
        do {
            streamDownloadHandle = try StreamDownloader(ytdlpURL: ytdlp).download(
                stream, plan: plan, ffmpegURL: ffmpeg,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.downloadingStreamID == id else { return }
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: Int(fraction * 100), jobsTotal: 100,
                            currentFilename: stream.title, isRunning: true)
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in self?.streamDownloadEnded(stream, plan: plan, result: result) }
                })
        } catch {
            endStreamDownloadUI()
            appAlert = .error(title: "Download Failed", message: error.localizedDescription)
        }
    }

    /// Stops yt-dlp for real (unlike conversion) and clears its partial file.
    func cancelStreamDownload() {
        streamDownloadHandle?.terminate()
    }

    private func streamDownloadEnded(_ stream: StreamSource, plan: StreamDownloadPlan,
                                     result: Result<URL, StreamDownloadError>) {
        endStreamDownloadUI()
        switch result {
        case .success(let fileURL):
            finishStreamDownload(stream, fileURL: fileURL)
        case .failure(let error):
            // yt-dlp leaves "<name>.m4a.part" (and .ytdl) behind when killed.
            if let leftovers = try? FileManager.default.contentsOfDirectory(at: plan.folder, includingPropertiesForKeys: nil) {
                for url in leftovers where ["part", "ytdl"].contains(url.pathExtension) {
                    try? FileManager.default.removeItem(at: url)
                }
                if (try? FileManager.default.contentsOfDirectory(atPath: plan.folder.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: plan.folder)
                }
            }
            if case .commandFailed(let status, let detail) = error, status != 15 {   // 15 = our own terminate
                // Same inline FIX panel a failed stream gets, not a throwaway alert.
                streamFailure = StreamFailureAdvisor.diagnose(detail: detail, ytdlpInstalled: true)
                AppLog.library.error("Stream download failed (\(status)): \(detail)")
            } else if error == .fileMissing {
                appAlert = .error(title: "Download Failed", message: "yt-dlp finished but the file was not written.")
            }
        }
    }

    private func endStreamDownloadUI() {
        streamDownloadHandle = nil
        downloadingStreamID = nil
        conversionProgress = .idle
        if oledView == .cdRip { oledView = .nowPlaying }
    }

    /// Cover, markers and tag defaults, then scan the folder into the Prep Crate.
    /// A download can run for minutes, so the drive that was connected when it
    /// started may not be by the time it finishes — re-check rather than trust
    /// the entry check in `downloadStream`. The file is left on disk either way;
    /// only the import (and the stream's `downloadedPath`) is refused.
    private func finishStreamDownload(_ stream: StreamSource, fileURL: URL) {
        guard !refuseWhileLibraryDisconnected() else { return }
        // The copy captured when the download began may predate its metadata.
        let stream = streams.first(where: { $0.id == stream.id }) ?? stream
        let markers = RecordMarker.markers(from: stream.chapters ?? [], duration: stream.durationSeconds)
        pendingStreamImports[fileURL.standardizedFileURL.path] = PendingStreamImport(
            streamID: stream.id, markers: markers, artist: stream.channel, album: stream.title)

        let folder = fileURL.deletingLastPathComponent()
        let thumbnail = stream.thumbnailURL.flatMap(URL.init(string:))
        Task { [weak self] in
            // Folder art is resolveArtwork's second rung; embedding a thumbnail in
            // m4a needs yt-dlp extras we cannot count on.
            if let thumbnail, let (data, _) = try? await URLSession.shared.data(from: thumbnail), !data.isEmpty {
                try? data.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
            }
            // `loadFolders` scans on its own Task and returns immediately: the
            // "Downloaded" success message belongs to whichever track actually
            // comes back out of that scan, not to this call site — see
            // `applyingPendingStreamImports`, which is the one place that knows.
            await MainActor.run { self?.loadFolders([folder]) }
        }
    }

    /// Called from `handleImport` before staging. Gives a just-downloaded file its
    /// chapter markers and the tags yt-dlp left blank, and links the stream to it.
    /// The scan surfaces artist/album for display from `AudioTrack`, not
    /// `ConversionMetadata` (see OLED, mini player, TAGS panel), so both are
    /// filled here.
    ///
    /// This is also the one place that knows a download's file really made it
    /// into a scanned `LoadedTrack` — so the "Downloaded" success message is
    /// posted from here, not from `finishStreamDownload`, which only knows it
    /// *started* a scan. A scan that yields nothing for this entry (a corrupt
    /// remux, a transient I/O error) posts nothing rather than claiming a
    /// success nobody observed.
    func applyingPendingStreamImports(to tracks: [LoadedTrack]) -> [LoadedTrack] {
        prunePendingStreamImports()
        guard !pendingStreamImports.isEmpty else { return tracks }
        // Collected rather than posted inline: setting `appAlert` from inside the
        // `map` would be a side effect per element, and if one scan ever matched
        // two pending entries (today's one-download-at-a-time flow keeps that from
        // happening, but `handleImport` is the general dig/drop path too, and a
        // future batch could reach it) only the last write would ever be seen.
        // Posting once after the map, for whichever matched last, makes that
        // "last one wins" explicit instead of an accident of iteration order.
        var lastDownloaded: PendingStreamImport?
        let result = tracks.map { loaded -> LoadedTrack in
            let path = loaded.track.fileURL.standardizedFileURL.path
            guard let pending = pendingStreamImports.removeValue(forKey: path) else { return loaded }
            var metadata = loaded.metadata
            var track = loaded.track
            if (metadata.artist ?? "").isEmpty { metadata.artist = pending.artist }
            if (metadata.album ?? "").isEmpty { metadata.album = pending.album }
            if track.artist.isEmpty { track.artist = pending.artist }
            if track.album.isEmpty { track.album = pending.album }
            streams = streamStore.setDownload(path: path, forStreamID: pending.streamID)
            lastDownloaded = pending
            return LoadedTrack(track: track, metadata: metadata,
                               recordMarkers: pending.markers.isEmpty ? nil : pending.markers)
        }
        if let pending = lastDownloaded {
            appAlert = .info(
                title: "Downloaded",
                message: pending.markers.isEmpty
                    ? "\u{201C}\(pending.album)\u{201D} is in the Prep Crate."
                    : "\u{201C}\(pending.album)\u{201D} is in the Prep Crate, divided into \(pending.markers.count) tracks. Convert it, or transfer it with a converting device profile, to get one file per track.")
        }
        return result
    }

    /// A pending entry only exists between a download finishing and its scan
    /// landing — normally milliseconds. If that scan never produces a matching
    /// track (the file was corrupt, or never appeared), the entry would
    /// otherwise sit forever: an unbounded leak, and — because
    /// `StreamDownloader.plan`'s path has no uniqueness suffix — a later,
    /// unrelated stream whose sanitized channel and title collide with it
    /// would silently inherit its stale artist/album/markers. Dropping
    /// anything older than a few minutes bounds both.
    private static let pendingStreamImportLifetime: TimeInterval = 5 * 60

    private func prunePendingStreamImports() {
        guard !pendingStreamImports.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Self.pendingStreamImportLifetime)
        let stale = pendingStreamImports.filter { $0.value.queuedAt < cutoff }
        guard !stale.isEmpty else { return }
        for (path, pending) in stale {
            pendingStreamImports.removeValue(forKey: path)
            AppLog.library.notice("Dropped an unconsumed stream download entry for \(pending.streamID, privacy: .public): its scan never produced a matching track.")
        }
    }

    private func confirmPersonalUse() -> Bool {
        guard !prefs.hasAcknowledgedStreamDownloadNotice else { return true }
        let alert = NSAlert()
        alert.messageText = "Downloads are for personal use"
        alert.informativeText = "Downloading keeps a copy of this stream on your Mac for your own offline listening. You are responsible for having the right to keep it. Do not share or redistribute what you download."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        prefs.hasAcknowledgedStreamDownloadNotice = true
        return true
    }
}
