import AppKit
import CrateDiggerCore
import Foundation

/// Radio / Streams behaviour. Selection, filtering, add/remove, and the live
/// uptime ticker. Actual audio playback is wired in Phase 3/4 via
/// `RadioPlaybackEngine` (see `playSelectedStream`).
@MainActor
extension LibraryViewModel {

    /// Enter radio mode, optionally filtered to one source category. Browsing a
    /// stream list must NOT start or stop playback — it only swaps the view. The
    /// currently-playing stream (if any) stays in `selectedStreamID`, so it keeps
    /// its highlight when it's visible in this category. Playing a stream is an
    /// explicit action (tapping a row, or `addStream`).
    func enterRadio(category: RadioCategory?) {
        selectSource(.radio(category: category))
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
            url: parsed.normalizedURL,
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
    ///
    /// Fetches run one after another: each one spawns a yt-dlp process, and the
    /// old fan-out started them all at once, so a library of saved streams put
    /// one subprocess per stream on the CPU the moment the app opened.
    func fetchMissingMetadata() {
        let ids = streams.filter { $0.thumbnailURL == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            for id in ids {
                await self?.fetchAndApplyMetadata(for: id)
            }
        }
    }

    /// Fetch real title/channel/thumbnail/live-status for one stream and apply it.
    /// Uses yt-dlp when available (richest), else YouTube oEmbed (no dependency).
    func fetchMetadata(for id: String) {
        Task { @MainActor [weak self] in await self?.fetchAndApplyMetadata(for: id) }
    }

    @MainActor
    private func fetchAndApplyMetadata(for id: String) async {
        guard let stream = streams.first(where: { $0.id == id }) else { return }
        let url = stream.url
        let ytdlp = resolvedYtDlpURL()
        let meta = ytdlp != nil
            ? await Self.fetchMetadataViaYtDlp(url: url, ytdlpURL: ytdlp!)
            : await Self.fetchMetadataViaOEmbed(url: url)
        guard let meta else { return }
        applyMetadata(meta, to: id)
    }

    private static func fetchMetadataViaYtDlp(url: String, ytdlpURL: URL) async -> StreamMetadata? {
        // Off the cooperative pool — yt-dlp blocks its thread outright.
        let result = try? await BlockingWork.run { () -> StreamMetadata? in
            // Bounded like every other yt-dlp/ffprobe caller: an unbounded run
            // left a wedged yt-dlp (throttled network, captcha wall) holding a
            // thread and a subprocess for the rest of the session.
            let runner = ProcessCommandRunner(timeoutSeconds: 30)
            guard let out = try? runner.run(executableURL: ytdlpURL,
                                            arguments: StreamMetadataService.ytdlpArguments(url: url)),
                  out.terminationStatus == 0 else { return nil }
            return StreamMetadataService.parseYtDlp(out.standardOutput)
        }
        return result ?? nil
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

        // The resume point is the second the record was interrupted by the radio.
        savePlaybackSnapshot()

        // Stop any library playback so we don't hear both.
        playback.pause()

        // Radio always uses the Now Playing OLED.
        oledView = .nowPlaying

        let engine = ensureRadioEngine()
        engine.play(stream)
        engine.setVolume(VolumeCurve.playerVolume(forPosition: playbackVolume))
        streamMeterTap.start()
    }

    /// Stops radio playback and the uptime ticker, and resets shared playback state.
    /// Tear the stream down completely. `radioEngine` being non-nil is what
    /// `isStreamActive` keys off, and that drives the OLED's ON AIR lamp and
    /// stream name — so releasing the engine is the whole point, not a detail.
    ///
    /// This used to reset state only `if isRadioMode`, and never released the
    /// engine. A stream that failed while you were browsing Radio therefore
    /// left ON AIR lit and its name on the display for the rest of the session:
    /// navigating to a crate made `isRadioMode` false, so playing a local track
    /// called this, stopped the engine, and then skipped the cleanup.
    func stopRadio() {
        streamMeterTap.stop()
        radioEngine?.stop()
        // Releasing the engine is enough — ensureRadioEngine() rebuilds when the
        // stored kind no longer has a live engine behind it.
        radioEngine = nil
        stopRadioUptimeTicker()
        radioUptimeSeconds = 0
        // Unconditional: the state being stale is exactly the bug, and the only
        // caller that isn't followed by new playback is an explicit stop.
        radioPublish(state: .idle)
        radioPublish(currentTime: 0, duration: 0)
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
                // Keep the diagnosis on the model so the radio list can offer a
                // FIX panel, rather than an alert the user dismisses and forgets.
                self.streamFailure = StreamFailureAdvisor.diagnose(
                    detail: message,
                    ytdlpInstalled: self.resolvedYtDlpURL() != nil
                )
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

    // MARK: - YouTube streaming health check

    /// Playback ▸ Stream Engine ▸ Check YouTube Streaming… — resolves a
    /// known-stable test video through the same yt-dlp path radio playback
    /// uses, then reports OK or offers the matching repair (install/update).
    func checkYouTubeStreaming() {
        guard let ytdlp = resolvedYtDlpURL() else {
            presentYtDlpMissing()
            return
        }
        showOLEDNotice("CHECKING YOUTUBE…")
        Task {
            guard let verdict = try? await BlockingWork.run({ StreamEngineDoctor().checkUp(ytdlpURL: ytdlp) }) else { return }
            await MainActor.run { self.presentStreamCheckVerdict(verdict, ytdlp: ytdlp) }
        }
    }

    private func presentYtDlpMissing() {
        let brew = Self.locateBrew()
        let alert = NSAlert()
        alert.messageText = "yt-dlp Not Found"
        alert.informativeText = "Radio streams YouTube through yt-dlp; without it CrateDigger falls back to the embedded WebView player."
            + (brew != nil
               ? "\n\nHomebrew is installed — CrateDigger can install yt-dlp for you (runs \"brew install yt-dlp\")."
               : "\n\nInstall Homebrew (brew.sh) and run \"brew install yt-dlp\", or download the binary from github.com/yt-dlp/yt-dlp and point Playback ▸ Stream Engine ▸ Set yt-dlp Path… at it.")
        if let brew {
            alert.addButton(withTitle: "Install with Homebrew")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                runRepairCommand(executablePath: brew.path,
                                 arguments: ["install", "yt-dlp"],
                                 notice: "INSTALLING YT-DLP…",
                                 label: "brew install yt-dlp")
            }
        } else {
            alert.addButton(withTitle: "Copy Install Command")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                showOLEDNotice("COMMAND COPIED")
            }
        }
    }

    private func presentStreamCheckVerdict(_ verdict: StreamEngineDoctor.Verdict, ytdlp: URL) {
        switch verdict {
        case .working(let version):
            oledNotice = nil
            appAlert = .info(
                title: "YouTube Streaming OK",
                message: "yt-dlp \(version) (\(ytdlp.path)) resolved the test video. Radio is good to go."
            )
        case .broken(let version, let detail):
            oledNotice = nil
            let realPath = ytdlp.resolvingSymlinksInPath().path
            let (exe, args) = StreamEngineDoctor.updateInvocation(realToolPath: realPath,
                                                                 brewPath: Self.locateBrew()?.path)
            let command = ([exe] + args).joined(separator: " ")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "YouTube Streaming Is Broken"
            alert.informativeText = """
            yt-dlp \(version) could not resolve the test video:

            \(detail)

            YouTube changes frequently and an outdated yt-dlp is the usual cause. Update it now? (runs "\(command)")
            """
            alert.addButton(withTitle: "Update yt-dlp")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                runRepairCommand(executablePath: exe, arguments: args,
                                 notice: "UPDATING YT-DLP…", label: command)
            }
        }
    }

    /// Runs an install/update command off-main, then re-runs the streaming
    /// check so the user sees end-to-end whether the repair actually worked.
    /// `onSuccess` runs after a zero-exit command, *instead of* jumping straight
    /// to a health check — an exit code says the command ran, not that it did
    /// anything, and some repairs have to verify their own work.
    private func runRepairCommand(executablePath: String, arguments: [String],
                                  notice: String, label: String,
                                  onSuccess: (() -> Void)? = nil) {
        showOLEDNotice(notice)
        Task {
            // brew can legitimately take a while; 10 min guards a wedged process.
            let output = try? await BlockingWork.run {
                try? ProcessCommandRunner(timeoutSeconds: 600)
                    .run(executableURL: URL(fileURLWithPath: executablePath), arguments: arguments)
            } ?? nil
            await MainActor.run {
                guard let output, output.terminationStatus == 0 else {
                    self.oledNotice = nil
                    let stderr = output?.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.appAlert = .error(
                        title: "Repair Failed",
                        message: "\"\(label)\" did not complete:\n\(stderr?.suffix(400) ?? "the command failed to launch")\n\nTry running it manually in Terminal."
                    )
                    return
                }
                if let onSuccess {
                    self.oledNotice = nil
                    onSuccess()
                } else {
                    self.checkYouTubeStreaming()
                }
            }
        }
    }

    /// yt-dlp's version string, or nil if it can't be asked.
    ///
    /// Off the main thread without exception: yt-dlp's standalone macOS build
    /// unpacks itself on every launch and takes ~6s just to print `--version`,
    /// which run inline would be a six-second frozen window.
    private func installedYtDlpVersion() async -> String? {
        guard let ytdlp = resolvedYtDlpURL() else { return nil }
        let output = try? await BlockingWork.run {
            try? ProcessCommandRunner(timeoutSeconds: 60)
                .run(executableURL: ytdlp, arguments: ["--version"])
        }
        return (output ?? nil)?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After an update command exits 0, check the version actually moved. When it
    /// hasn't — the package manager's formula is behind, which for Homebrew is
    /// routine — say so plainly and offer the one route that isn't hostage to it.
    private func confirmYtDlpMoved(from before: String?) {
        showOLEDNotice("CHECKING VERSION…")
        Task { @MainActor in
            let after = await self.installedYtDlpVersion()
            self.oledNotice = nil
            guard !StreamEngineDoctor.versionChanged(from: before, to: after) else {
                self.checkYouTubeStreaming()
                return
            }
            self.offerStandaloneYtDlp(currentVersion: after)
        }
    }

    /// The package manager is behind. Say so, and offer the direct download.
    private func offerStandaloneYtDlp(currentVersion: String?) {
        let after = currentVersion
        let alert = NSAlert()
        alert.messageText = "yt-dlp Is Already the Newest Your Package Manager Has"
        alert.informativeText = """
            The update ran, but yt-dlp is still \(after ?? "the same version").             Homebrew's formula often trails yt-dlp's own releases by weeks, and             YouTube breaks extractors faster than that.

            CrateDigger can download yt-dlp's latest release directly and use             that copy instead. Your Homebrew install is left alone.
            """
        alert.addButton(withTitle: "Download Latest")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installStandaloneYtDlp()
    }


    /// Fetch yt-dlp's own macOS build into Application Support and point the
    /// custom-path preference at it, so it outranks whatever the package manager
    /// has. Nothing else on the system is touched.
    private func installStandaloneYtDlp() {
        showOLEDNotice("DOWNLOADING YT-DLP…")
        let destination = StreamEngineDoctor.standaloneDestination()
        Task { @MainActor in
            do {
                let (temporary, response) = try await URLSession.shared
                    .download(from: StreamEngineDoctor.standaloneDownloadURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "CrateDigger.YtDlpInstall", code: 1, userInfo: [
                        NSLocalizedDescriptionKey:
                            "The download server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."
                    ])
                }
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temporary, to: destination)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

                prefs.customYtDlpPath = destination.path
                oledNotice = nil
                AppLog.library.notice("Installed standalone yt-dlp at \(destination.path, privacy: .public)")
                checkYouTubeStreaming()
            } catch {
                oledNotice = nil
                appAlert = .error(
                    title: "Couldn't Download yt-dlp",
                    message: "\(error.localizedDescription)\n\nYou can install it yourself from "
                        + "github.com/yt-dlp/yt-dlp and point Playback ▸ Stream Engine ▸ Set yt-dlp Path… at it."
                )
            }
        }
    }

    private static func locateBrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Failure remedies (the FIX panel)

    /// Re-run the last stream after a repair, or just clear the banner.
    func retryFailedStream() {
        streamFailure = nil
        guard selectedStream != nil else { return }
        playSelectedStream()
    }

    func dismissStreamFailure() { streamFailure = nil }

    /// Carry out a remedy the advisor offered.
    func applyStreamRemedy(_ remedy: StreamFailureAdvisor.Remedy) {
        switch remedy {
        case .installYtDlp:
            presentYtDlpMissing()
        case .updateYtDlp:
            guard let ytdlp = resolvedYtDlpURL() else { presentYtDlpMissing(); return }
            let realPath = ytdlp.resolvingSymlinksInPath().path
            let (exe, args) = StreamEngineDoctor.updateInvocation(
                realToolPath: realPath, brewPath: Self.locateBrew()?.path
            )
            streamFailure = nil
            Task { @MainActor in
                let before = await self.installedYtDlpVersion()
                self.runRepairCommand(
                    executablePath: exe, arguments: args,
                    notice: "UPDATING YT-DLP…", label: ([exe] + args).joined(separator: " ")
                ) { [weak self] in self?.confirmYtDlpMoved(from: before) }
            }
        case .useWebViewEngine:
            prefs.streamEngine = "webview"
            streamEnginePreferenceChanged()
            streamFailure = nil
            showOLEDNotice("WEBVIEW PLAYER")
            if selectedStream != nil { playSelectedStream() }
        case .waitAndRetry:
            retryFailedStream()
        case .tryAnotherSource:
            streamFailure = nil
            showingStreamSuggestions = true
        case .fixURL:
            streamFailure = nil
            showingAddStreamSheet = true
        }
    }

    /// Add a curated station and jump to it.
    func addSuggestedStream(_ suggestion: StreamSuggestion) {
        showingStreamSuggestions = false
        addStream(fromURL: suggestion.url)
    }

    /// Suggestions that aren't already saved, for the category being browsed.
    func availableSuggestions(for category: RadioCategory?) -> [StreamSuggestion] {
        let savedURLs = Set(streams.map { $0.url })
        let pool = category.map { StreamSuggestion.catalog(for: $0) } ?? StreamSuggestion.catalog
        return pool.filter { !savedURLs.contains($0.url) }
    }

}
