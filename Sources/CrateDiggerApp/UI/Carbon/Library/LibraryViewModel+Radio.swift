import CrateDiggerCore
import Foundation

/// Radio / Streams behaviour. Selection, filtering, add/remove, and the live
/// uptime ticker. Actual audio playback is wired in Phase 3/4 via
/// `RadioPlaybackEngine` (see `playSelectedStream`).
@MainActor
extension LibraryViewModel {

    /// Enter radio mode, optionally filtered to one channel, and select a stream
    /// (the previously-playing one if still visible, else the first in the list).
    func enterRadio(channel: String?) {
        selectSource(.radio(channel: channel))
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
        // If we're filtered to a different channel, widen to All so the new one shows.
        let channel: String? = (radioChannelFilter == nil || radioChannelFilter == stream.channel)
            ? radioChannelFilter : nil
        enterRadio(channel: channel)
        selectStream(id: stream.id)
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

    // MARK: - Playback (stubbed in Phase 2; implemented in Phase 3/4)

    /// Starts the selected stream on the active engine. No-op until the engines land.
    func playSelectedStream() {
        // Phase 3: create/reuse the RadioPlaybackEngine and call play(selectedStream).
    }

    /// Stops radio playback and the uptime ticker.
    func stopRadio() {
        stopRadioUptimeTicker()
        // Phase 3: radioEngine?.stop()
    }
}
