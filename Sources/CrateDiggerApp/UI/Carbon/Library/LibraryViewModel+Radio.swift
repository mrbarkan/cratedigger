import CrateDiggerCore
import Foundation

/// Radio / Streams behaviour. Selection, filtering, add/remove, and the live
/// uptime ticker. Actual audio playback is wired in Phase 3/4 via
/// `RadioPlaybackEngine` (see `playSelectedStream`).
@MainActor
extension LibraryViewModel {

    /// Enter radio mode, optionally filtered to one source category, and select a
    /// stream (the previously-playing one if still visible, else the first listed).
    func enterRadio(category: RadioCategory?) {
        selectSource(.radio(category: category))
        let visible = filteredStreams
        if let current = selectedStreamID, visible.contains(where: { $0.id == current }) {
            selectStream(id: current)
        } else if let first = visible.first {
            selectStream(id: first.id)
        } else {
            selectedStreamID = nil
        }
    }

    /// Select a stream and (Phase 3+) start playing it.
    func selectStream(id: String) {
        guard streams.contains(where: { $0.id == id }) else { return }
        selectedStreamID = id
        startUptimeTickerIfNeeded()
        playSelectedStream()
    }

    /// Parse a pasted URL, persist it as a new stream, and jump to it.
    func addStream(fromURL raw: String) {
        guard let parsed = StreamURLParser.parse(raw) else {
            appAlert = .error(title: "Invalid Link",
                              message: "That doesn't look like a URL CrateDigger can stream.")
            return
        }
        guard parsed.isValidHost else {
            appAlert = .error(title: "Not a YouTube Link",
                              message: "Only YouTube channels, playlists, live streams, and videos are supported right now.")
            return
        }
        let stream = StreamSource(
            id: "u" + UUID().uuidString,
            url: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            title: parsed.suggestedTitle,
            channel: parsed.channel,
            kind: parsed.kind,
            hue: Int.random(in: 0...359),
            addedAt: Date(),
            viewers: parsed.kind == .live ? "0" : nil
        )
        streams = streamStore.add(stream)
        // If we're filtered to a category the new stream isn't in, widen to All
        // so it shows (its live-ness may also change once metadata arrives).
        let category: RadioCategory? = radioCategoryFilter.flatMap {
            $0.contains(stream) ? $0 : nil
        }
        enterRadio(category: category)
        selectStream(id: stream.id)
        fetchMetadata(for: stream.id)
    }

    // MARK: - Metadata (real title / channel / thumbnail)

    /// Fetch real metadata for every stream that doesn't have a thumbnail yet
    /// (newly added, or saved before metadata existed). Called on launch.
    func fetchMissingMetadata() {
        for stream in streams where stream.thumbnailURL == nil {
            fetchMetadata(for: stream.id)
        }
    }

    /// Fetch real title/channel/thumbnail/live-status for one stream and apply it.
    /// Uses yt-dlp when available (richest), else YouTube oEmbed (no dependency).
    func fetchMetadata(for id: String) {
        guard let stream = streams.first(where: { $0.id == id }) else { return }
        let url = stream.url
        let ytdlp = resolvedYtDlpURL()
        Task { [weak self] in
            let meta = ytdlp != nil
                ? await Self.fetchMetadataViaYtDlp(url: url, ytdlpURL: ytdlp!)
                : await Self.fetchMetadataViaOEmbed(url: url)
            guard let meta else { return }
            await MainActor.run { self?.applyMetadata(meta, to: id) }
        }
    }

    private static func fetchMetadataViaYtDlp(url: String, ytdlpURL: URL) async -> StreamMetadata? {
        await Task.detached {
            let runner = ProcessCommandRunner()
            guard let out = try? runner.run(executableURL: ytdlpURL,
                                            arguments: StreamMetadataService.ytdlpArguments(url: url)),
                  out.terminationStatus == 0 else { return nil }
            return StreamMetadataService.parseYtDlp(out.standardOutput)
        }.value
    }

    private static func fetchMetadataViaOEmbed(url: String) async -> StreamMetadata? {
        guard let endpoint = StreamMetadataService.oEmbedURL(for: url),
              let (data, _) = try? await URLSession.shared.data(from: endpoint) else { return nil }
        return StreamMetadataService.parseOEmbed(data)
    }

    private func applyMetadata(_ meta: StreamMetadata, to id: String) {
        guard let idx = streams.firstIndex(where: { $0.id == id }) else { return }
        var s = streams[idx]
        if let title = meta.title, !title.isEmpty { s.title = title }
        if let channel = meta.channel, !channel.isEmpty { s.channel = channel }
        if let thumb = meta.thumbnailURL { s.thumbnailURL = thumb }
        if let dur = meta.durationSeconds { s.durationSeconds = dur }
        if let viewers = meta.viewers { s.viewers = viewers }
        if let chapters = meta.chapters { s.chapters = chapters }
        if meta.isLive == true { s.kind = .live }
        else if meta.isLive == false && s.kind == .live { s.kind = .video }
        streams[idx] = s
        streamStore.save(streams)

        // Keep live uptime ticker in sync if this is the playing stream.
        if selectedStreamID == id { startUptimeTickerIfNeeded() }
    }

    /// Seek the playing stream to a chapter's start (clicking a track in the list).
    func seekToChapter(_ chapter: StreamChapter) {
        guard isRadioMode, selectedStream != nil else { return }
        // Start it if nothing is playing yet.
        if radioEngine == nil { playSelectedStream() }
        radioEngine?.seek(toSeconds: chapter.startSeconds)
        // Optimistic position so the tracklist + OLED highlight update immediately.
        radioPublish(currentTime: chapter.startSeconds, duration: playbackDuration)
    }

    func removeStream(id: String) {
        streams = streamStore.remove(id: id)
        if selectedStreamID == id {
            selectedStreamID = filteredStreams.first?.id
            if let next = selectedStreamID { selectStream(id: next) } else { stopRadio() }
        }
    }

    // MARK: - Uptime ticker

    private func startUptimeTickerIfNeeded() {
        radioUptimeTimer?.invalidate()
        radioUptimeTimer = nil
        radioUptimeSeconds = Int(selectedStream?.durationSeconds ?? 0)
        guard let stream = selectedStream, stream.isLive else { return }
        radioUptimeSeconds = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRadioMode, self.playbackState == .playing else { return }
                self.radioUptimeSeconds += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        radioUptimeTimer = timer
    }

    func stopRadioUptimeTicker() {
        radioUptimeTimer?.invalidate()
        radioUptimeTimer = nil
    }

    // MARK: - Playback

    /// Starts the selected stream on the active engine. Stops file playback first
    /// (they're mutually exclusive), creates/reuses the engine, and mirrors its
    /// state onto the shared `playbackState` / time so the OLED + footer react.
    func playSelectedStream() {
        guard let stream = selectedStream else { return }

        // Stop any library playback so we don't hear both.
        playback.pause()

        // Radio always uses the Now Playing OLED.
        oledView = .nowPlaying

        let engine = ensureRadioEngine()
        engine.play(stream)
        engine.setVolume(playbackVolume)
    }

    /// Stops radio playback and the uptime ticker, and resets shared playback state.
    func stopRadio() {
        radioEngine?.stop()
        stopRadioUptimeTicker()
        if isRadioMode {
            radioPublish(state: .idle)
            radioPublish(currentTime: 0, duration: 0)
        }
    }

    /// Lazily builds the engine for the current `streamEngine` preference, wiring
    /// its callbacks onto the view model's shared playback state.
    private func ensureRadioEngine() -> RadioPlaybackEngine {
        let kind = resolveActiveEngineKind()
        // Reuse only if the kind matches; otherwise rebuild.
        if let existing = radioEngine, kind == radioEngineKind {
            return existing
        }
        radioEngine?.stop()
        radioEngineKind = kind
        radioEngineLabel = engineLabel(for: kind)

        let engine = makeEngine(for: kind)
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:    self.radioPublish(state: .idle)
            case .loading: self.radioPublish(state: .loading)
            case .playing: self.radioPublish(state: .playing)
            case .paused:  self.radioPublish(state: .paused)
            case .failed(let message):
                self.radioPublish(state: .failed(message: message))
                self.appAlert = .error(title: "Stream Problem", message: message)
            }
        }
        engine.onTimeChange = { [weak self] current, duration in
            guard let self else { return }
            self.radioPublish(currentTime: current, duration: duration)
        }
        radioEngine = engine
        return engine
    }

    private func makeEngine(for kind: RadioEngineKind) -> RadioPlaybackEngine {
        switch kind {
        case .webview:
            return YouTubeEmbedStreamEngine()
        case .native:
            guard let url = resolvedYtDlpURL() else {
                // Shouldn't happen (resolveActiveEngineKind guards), but fall back safely.
                return YouTubeEmbedStreamEngine()
            }
            let engine = YtDlpStreamEngine(resolver: StreamResolver(ytdlpURL: url))
            engine.setOutputDeviceUID(prefs.selectedOutputDeviceUID)
            return engine
        }
    }

    /// Resolves the engine from the `streamEngine` preference plus yt-dlp
    /// availability. `auto` prefers native when yt-dlp is present, else WebView.
    func resolveActiveEngineKind() -> RadioEngineKind {
        switch prefs.streamEngine {
        case "webview":
            return .webview
        case "native":
            return resolvedYtDlpURL() != nil ? .native : .webview
        default: // "auto"
            return resolvedYtDlpURL() != nil ? .native : .webview
        }
    }

    /// The yt-dlp binary to use: a user-set custom path (Settings) overrides the
    /// PATH search. nil when yt-dlp can't be found (bring-your-own).
    func resolvedYtDlpURL() -> URL? {
        let override = prefs.customYtDlpPath.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        }
        return ExternalToolLocator().resolveOptional(.ytdlp, explicitOverride: override)?.url
    }

    private func engineLabel(for kind: RadioEngineKind) -> String {
        switch prefs.streamEngine {
        case "native":  return kind == .native ? "NATIVE" : "WEB*"   // * = requested native, fell back
        case "webview": return "WEB"
        default:        return kind == .native ? "AUTO·N" : "AUTO·W"
        }
    }

    /// Called after the user changes the engine pref (or yt-dlp path) in the menu.
    /// Refreshes the OLED label and, if a stream is currently playing, restarts it
    /// on the newly-selected engine.
    func streamEnginePreferenceChanged() {
        let kind = resolveActiveEngineKind()
        radioEngineKind = kind
        radioEngineLabel = engineLabel(for: kind)

        if prefs.streamEngine == "native" && resolvedYtDlpURL() == nil {
            appAlert = .error(
                title: "yt-dlp Not Found",
                message: "CrateDigger will use the built-in WebView player until you install yt-dlp or set its path in the menu."
            )
        }

        if isRadioMode, selectedStream != nil, radioEngine != nil {
            radioEngine?.stop()
            radioEngine = nil
            playSelectedStream()
        }
    }
}
