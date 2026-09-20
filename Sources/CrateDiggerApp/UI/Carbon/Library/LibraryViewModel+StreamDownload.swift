import AppKit
import CrateDiggerCore
import Foundation

/// A downloaded stream waiting for its scan: the markers and tag defaults the
/// scanner cannot know, and the stream to link the file back to.
struct PendingStreamImport {
    let streamID: String
    let markers: [RecordMarker]
    let artist: String
    let album: String
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
        guard let ytdlp = resolvedYtDlpURL() else {
            appAlert = .error(title: "yt-dlp Not Found",
                              message: "Downloading needs yt-dlp. Install it (for example with Homebrew: brew install yt-dlp) or set its path in Settings.")
            return
        }
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
            // Already on disk from an earlier run: adopt it instead of fetching again.
            return finishStreamDownload(stream, fileURL: plan.fileURL)
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
    private func finishStreamDownload(_ stream: StreamSource, fileURL: URL) {
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
            await MainActor.run {
                guard let self else { return }
                self.loadFolders([folder])
                self.appAlert = .info(
                    title: "Downloaded",
                    message: markers.isEmpty
                        ? "\u{201C}\(stream.title)\u{201D} is in the Prep Crate."
                        : "\u{201C}\(stream.title)\u{201D} is in the Prep Crate, divided into \(markers.count) tracks. Convert it, or transfer it with a converting device profile, to get one file per track.")
            }
        }
    }

    /// Called from `handleImport` before staging. Gives a just-downloaded file its
    /// chapter markers and the tags yt-dlp left blank, and links the stream to it.
    /// The scan surfaces artist/album for display from `AudioTrack`, not
    /// `ConversionMetadata` (see OLED, mini player, TAGS panel), so both are
    /// filled here.
    func applyingPendingStreamImports(to tracks: [LoadedTrack]) -> [LoadedTrack] {
        guard !pendingStreamImports.isEmpty else { return tracks }
        return tracks.map { loaded in
            let path = loaded.track.fileURL.standardizedFileURL.path
            guard let pending = pendingStreamImports.removeValue(forKey: path) else { return loaded }
            var metadata = loaded.metadata
            var track = loaded.track
            if (metadata.artist ?? "").isEmpty { metadata.artist = pending.artist }
            if (metadata.album ?? "").isEmpty { metadata.album = pending.album }
            if track.artist.isEmpty { track.artist = pending.artist }
            if track.album.isEmpty { track.album = pending.album }
            streams = streamStore.setDownload(path: path, forStreamID: pending.streamID)
            return LoadedTrack(track: track, metadata: metadata,
                               recordMarkers: pending.markers.isEmpty ? nil : pending.markers)
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
