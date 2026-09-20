import AppKit
import CrateDiggerCore
import Foundation

/// A downloaded file waiting for the scan that will turn it into a library
/// track: the markers and tag defaults the scanner cannot know, and the stream
/// to link it back to. Queued by `addDownloadToCrate`, never by the download
/// itself — a download does not enter the library on its own. `queuedAt` bounds
/// how long an entry can wait — see `prunePendingStreamImports()`.
struct PendingStreamImport {
    let streamID: String
    let markers: [RecordMarker]
    let artist: String
    let album: String
    let queuedAt: Date = Date()
}

/// Download for Offline: yt-dlp saves a stream's audio to disk and the stream
/// plays from that copy instead of the network. **It does not enter the
/// library.** A download is a property of the stream, not a record you dug —
/// it belongs in Radio ▸ Downloads, not in the Prep Crate waiting to be filed.
///
/// Filing it is a separate, explicit act: `addDownloadToCrate` scans the file
/// into a crate the user names, and only then does it become an ordinary
/// `LoadedTrack` that conversion, Record Divider and device transfer can reach
/// — which is how a download gets split into per-chapter tracks for an
/// external device. yt-dlp is bring-your-own, as for playback.
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
        guard !isConversionRunning else { return showOLEDNotice("BUSY") }
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
        streamDownloadCancelled = false
        oledView = .dub
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 100,
                                                        currentFilename: stream.title, isRunning: true)
        let ffmpeg = ExternalToolLocator().resolveOptional(.ffmpeg)?.url
        do {
            streamDownloadHandle = try StreamDownloader(ytdlpURL: ytdlp).download(
                stream, plan: plan, ffmpegURL: ffmpeg,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.downloadingStreamID == id else { return }
                        let percent = Int(fraction * 100)
                        // yt-dlp's --newline progress can fire many times a
                        // second; skip the write (and the SwiftUI diff it
                        // triggers) when the integer percent hasn't moved.
                        guard percent != self.conversionProgress.jobsCompleted else { return }
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: percent, jobsTotal: 100,
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
        streamDownloadCancelled = true
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
            if case .commandFailed(let status, let detail) = error, !streamDownloadCancelled {
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
        if oledView == .dub { oledView = .nowPlaying }
    }

    /// Link the file to its stream and fetch the cover. Nothing is scanned and
    /// nothing is staged: the stream now plays offline, and that is the whole
    /// job. Filing it into the library is `addDownloadToCrate`, on request.
    ///
    /// A download can run for minutes, so the drive that was connected when it
    /// started may not be by the time it finishes — re-check rather than trust
    /// the entry check in `downloadStream`. The file is left on disk either way;
    /// only the link (and so the offline playback) is refused, because
    /// `downloadedPath` lives in the library's own store.
    private func finishStreamDownload(_ stream: StreamSource, fileURL: URL) {
        guard !refuseWhileLibraryDisconnected() else { return }
        // The copy captured when the download began may predate its metadata.
        let stream = streams.first(where: { $0.id == stream.id }) ?? stream
        let path = fileURL.standardizedFileURL.path
        streams = streamStore.setDownload(path: path, forStreamID: stream.id)

        let folder = fileURL.deletingLastPathComponent()
        let thumbnail = stream.thumbnailURL.flatMap(URL.init(string:))
        Task { [weak self] in
            // Folder art is resolveArtwork's second rung; embedding a thumbnail in
            // m4a needs yt-dlp extras we cannot count on. Only useful once the
            // file is filed into a crate, but the thumbnail URL expires, so it
            // is fetched now rather than whenever that happens.
            if let thumbnail, let (data, _) = try? await URLSession.shared.data(from: thumbnail), !data.isEmpty {
                try? data.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
            }
        }

        let chapters = stream.chapters?.count ?? 0
        appAlert = .info(
            title: "Downloaded",
            message: chapters > 1
                ? "\u{201C}\(stream.title)\u{201D} plays offline now. It has \(chapters) chapters, so adding it to a crate will split it into tracks you can convert or send to a device."
                : "\u{201C}\(stream.title)\u{201D} plays offline now. Add it to a crate if you want to convert it or send it to a device.")
    }

    /// File a downloaded stream into a crate on request: the one way a download
    /// becomes an ordinary library track. Reuses the Finder-drop path
    /// (`addURLsToCrate`), so copy-on-import, artwork ingest and crate
    /// persistence all behave exactly as they do for any other import — the only
    /// thing added is the pending entry that carries the chapter markers and the
    /// tags yt-dlp left blank through that scan.
    func addDownloadToCrate(streamID: String, crateName: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard let stream = streams.first(where: { $0.id == streamID }),
              let path = stream.downloadedPath else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            appAlert = .error(title: "File Missing",
                              message: "The offline copy is no longer on disk. Download it again.")
            return
        }
        let markers = RecordMarker.markers(from: stream.chapters ?? [], duration: stream.durationSeconds)
        pendingStreamImports[path] = PendingStreamImport(
            streamID: streamID, markers: markers, artist: stream.channel, album: stream.title)
        addURLsToCrate([URL(fileURLWithPath: path)], crateName: crateName)
    }

    /// Called from the two scan-into-the-library paths (`handleImport` for a dig
    /// or a Finder drop, `addURLsToCrate` for a crate drop or an explicit
    /// `addDownloadToCrate`) before the tracks are filed. Gives a downloaded file
    /// its chapter markers and the tags yt-dlp left blank. The scan surfaces
    /// artist/album for display from `AudioTrack`, not `ConversionMetadata` (see
    /// OLED, mini player, TAGS panel), so both are filled here.
    ///
    /// This is also the one place that knows a download's file really made it
    /// into a scanned `LoadedTrack`, so the "Added to <crate>" confirmation is
    /// posted from here rather than from `addDownloadToCrate`, which only knows
    /// it *started* a scan. A scan that yields nothing for this entry (a corrupt
    /// remux, a transient I/O error) posts nothing rather than claiming a
    /// success nobody observed.
    func applyingPendingStreamImports(to tracks: [LoadedTrack]) -> [LoadedTrack] {
        prunePendingStreamImports()
        guard !pendingStreamImports.isEmpty else { return tracks }
        // Collected rather than posted inline: setting `appAlert` from inside the
        // `map` would be a side effect per element, and if one scan ever matched
        // two pending entries (a Finder drop of two previously-downloaded files
        // reaches this the same way an explicit add does) only the last write
        // would ever be seen. Posting once after the map, for whichever matched
        // last, makes that "last one wins" explicit instead of an accident of
        // iteration order.
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
        if let pending = lastDownloaded, !pending.markers.isEmpty {
            // Only the divided case is worth an alert: the plain "it is in the
            // crate you just picked" case is already visible in the browser,
            // and `finishImportStatus` says it on the OLED rail.
            appAlert = .info(
                title: "Added to Your Library",
                message: "\u{201C}\(pending.album)\u{201D} is divided into \(pending.markers.count) tracks. Convert it, or transfer it with a converting device profile, to get one file per track.")
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

    /// Whether the offline copy has been filed into the library as a track —
    /// which decides whether the row offers "Show in Library" or "Add to Crate".
    func isDownloadFiled(streamID: String) -> Bool {
        guard let stream = streams.first(where: { $0.id == streamID }) else { return false }
        return downloadedTrack(for: stream) != nil
    }

    /// The downloaded file as the library knows it, wherever it is filed.
    private func downloadedTrack(for stream: StreamSource) -> LoadedTrack? {
        guard let path = stream.downloadedPath else { return nil }
        let match: (LoadedTrack) -> Bool = { $0.track.fileURL.standardizedFileURL.path == path }
        return prepCrateTracks.first(where: match) ?? localIndex.allTracks.first(where: match)
    }

    /// Trash the offline copy; the stream stays and plays online again.
    func removeDownload(streamID: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard let stream = streams.first(where: { $0.id == streamID }), let path = stream.downloadedPath else { return }

        let alert = NSAlert()
        alert.messageText = "Move the offline copy of \u{201C}\(stream.title)\u{201D} to the Trash?"
        // A download only reaches the library if the user filed it there, so
        // promising that "the track leaves your library" is a lie in the
        // ordinary case — there is no track.
        alert.informativeText = downloadedTrack(for: stream) == nil
            ? "The stream stays in your list and plays online again."
            : "The stream stays in your list and plays online. The track leaves your library along with it, and its play history goes with it."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Let go of the file before it moves: the radio engine if it is playing
        // this offline copy, the library player if the track was started from a crate.
        if selectedStreamID == streamID, radioEngine != nil { stopRadio() }
        if let current = nowPlayingTrack, current.track.fileURL.standardizedFileURL.path == path { playback.pause() }

        let fileURL = URL(fileURLWithPath: path)
        do {
            if let track = downloadedTrack(for: stream) {
                try LibraryCleanupService().deleteTracks([track], useTrash: true)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            }
        } catch {
            // Link left intact: the file is still there and still the download.
            appAlert = .error(title: "Trash Failed", message: error.localizedDescription)
            return
        }
        purgeTracksFromLibraryState(paths: [path])

        // Pausing only silences the engine; the queue still names the trashed
        // file, so pressing play would try to resume it from the Trash. Rebuild
        // the queue without it, landing paused on whatever is next.
        if let idx = playbackQueue.firstIndex(where: { $0.track.fileURL.standardizedFileURL.path == path }) {
            playbackQueue.remove(at: idx)
            let nextIndex = min(idx, max(playbackQueue.count - 1, 0))
            playback.load(queue: playbackQueue.map(Self.queueItem), startIndex: nextIndex, autoPlay: false)
        }

        // The folder was made for this download; take it too when only the
        // cover is left AND it is still that folder. A repoint (retag, auto
        // organize, library move) can have since moved the track into a
        // folder the user owns, which can just as easily hold nothing but its
        // own track and cover.jpg; only trash the folder when its name still
        // identifies it as the one this download created.
        let folder = fileURL.deletingLastPathComponent()
        if StreamDownloader.isDownloadFolder(folder, for: stream) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if StreamDownloader.isDisposableLeftover(contents: contents) {
                try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
        }

        streams = streamStore.setDownload(path: nil, forStreamID: streamID)

        // This was the only way this call can empty the filtered list: a
        // sidebar row that just vanished would otherwise strand the browser
        // on a filter it can no longer reach or add anything from. Route
        // through enterRadio rather than clearing radioCategoryFilter alone,
        // or currentSource keeps naming the now-empty category and the next
        // selectSource(currentSource) (purgeTracksFromLibraryState above
        // already ran one) re-applies it over an empty list.
        if radioCategoryFilter != nil, filteredStreams.isEmpty { enterRadio(category: nil) }

        showOLEDNotice("DOWNLOAD REMOVED")
    }

    func showDownloadInLibrary(streamID: String) {
        guard let stream = streams.first(where: { $0.id == streamID }),
              let track = downloadedTrack(for: stream) else { return }
        let inPrep = prepCrateTracks.contains { $0.track.fileURL == track.track.fileURL }
        selectSource(inPrep ? .prepCrate : .localAll)
        revealTrack(track)
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
