import AppKit
import MediaPlayer
import CrateDiggerCore
import NowPlayingFeed
import WidgetKit

/// Bridges playback to macOS system media: hardware media keys (F7/F8/F9),
/// AirPods gestures, Control Center, and the lock-screen "Now Playing" widget.
/// Also feeds CrateDigger's own Now Playing widget, from the same moments.
///
/// `MPRemoteCommandCenter` captures the transport commands and forwards them to
/// the same `togglePlayPause()` / `next()` / `previous()` the on-screen buttons
/// use; `MPNowPlayingInfoCenter` publishes the metadata those surfaces display.
/// macOS routes the hardware media keys to whichever app registered remote
/// commands and has non-nil now-playing info with a playing rate — no private
/// API and no entitlement required.
///
/// Registered once at launch (`configureNowPlaying()`), then kept in sync from
/// the playback callbacks in `wirePlaybackBindings()`.
@MainActor
extension LibraryViewModel {
    /// Register the transport command handlers. Called once during init.
    func configureNowPlaying() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackState != .playing else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackState == .playing else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        // Commands we don't implement stay disabled so the system doesn't show
        // dead scrubbers/skip controls. (Position scrubbing is a possible follow-up.)
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    /// Push the full now-playing metadata (title/artist/album/artwork/duration).
    /// Cheap enough to call on every track and play/pause change — artwork comes
    /// from the same NSCache-backed thumbnail path the mini-player uses.
    func refreshNowPlayingInfo() {
        // After the anchor below moves: the widget's playhead is the anchor.
        defer { publishWidgetFeed() }
        let center = MPNowPlayingInfoCenter.default()
        guard let track = nowPlayingTrack else {
            // Nothing local playing (idle, or a radio stream — a follow-up).
            center.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.track.title,
            MPMediaItemPropertyArtist: track.track.artist,
            MPMediaItemPropertyAlbumTitle: track.track.album,
            MPMediaItemPropertyPlaybackDuration: playbackDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0,
        ]
        if let hash = track.track.artworkHash,
           let image = artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: 480, height: 480)) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        nowPlayingElapsedAnchor = (playbackCurrentTime, Date(), info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0)
    }

    /// Keep the system scrubber honest without per-tick IPC: macOS extrapolates
    /// elapsed time from the last pushed (elapsed, rate) on its own, so this
    /// only re-pushes when actual playback has diverged from that extrapolation
    /// (a seek/jump from any path — scrub dial, ±8s, record-divider, radio VOD).
    /// During normal playback the guard never trips and no push happens.
    func updateNowPlayingElapsed() {
        let rate = playbackState == .playing ? 1.0 : 0.0
        if let anchor = nowPlayingElapsedAnchor, rate == anchor.rate {
            let extrapolated = anchor.elapsed + anchor.rate * Date().timeIntervalSince(anchor.wall)
            if abs(playbackCurrentTime - extrapolated) < 1.0 { return }
        }

        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackCurrentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        center.nowPlayingInfo = info
        nowPlayingElapsedAnchor = (playbackCurrentTime, Date(), rate)
        publishWidgetFeed()
    }

    // MARK: - Now Playing widget

    /// Where the widget reads from, or nil when this build carries no widget
    /// (a `swift build` run, an ad-hoc package): with nothing to read the feed,
    /// there is no reason to reach into the app-group container at all.
    static let widgetFeedStore: NowPlayingFeedStore? = {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              FileManager.default.fileExists(atPath: plugIns.appendingPathComponent("CrateDiggerWidget.appex").path),
              let container = NowPlayingFeed.containerURL()
        else { return nil }
        return NowPlayingFeedStore(directory: container)
    }()

    /// Hand the widget what is playing. Called wherever the system's
    /// now-playing info is pushed, after the elapsed anchor moves, and when a
    /// stream changes state. The playhead is the anchor rather than the clock,
    /// so a track that just plays on writes nothing: the widget extrapolates
    /// from (playhead, playheadAt) itself. The store drops identical feeds, and
    /// only a real change reloads the widget.
    func publishWidgetFeed() {
        // A load in progress is on its way to playing or paused; publishing it
        // would flash a paused widget between every track.
        guard playbackState != .loading else { return }
        let (feed, artworkHash) = currentWidgetFeed()
        writeWidgetFeed(feed, artworkHash: artworkHash)
    }

    /// At quit, so the widget does not go on showing a track nobody is playing.
    func clearWidgetFeed() {
        writeWidgetFeed(.idle, artworkHash: nil)
    }

    private func currentWidgetFeed() -> (NowPlayingFeed, String?) {
        let state: NowPlayingFeed.State = playbackState == .playing ? .playing : .paused
        if isStreamActive, let stream = selectedStream {
            return (NowPlayingFeed(state: state, title: stream.title, artist: stream.channel, isLive: true), nil)
        }
        guard let track = nowPlayingTrack, playbackState != .idle, let anchor = nowPlayingElapsedAnchor else {
            return (.idle, nil)
        }
        // The tag duration, not the player's: that one arrives a moment after
        // the track does, and the tick that brings it does not publish.
        let duration = track.track.durationSeconds > 0 ? track.track.durationSeconds : playbackDuration
        let hash = track.track.artworkHash
        let feed = NowPlayingFeed(
            state: state,
            title: track.track.title,
            artist: track.track.artist,
            album: track.track.album,
            duration: duration,
            playhead: anchor.elapsed,
            playheadAt: anchor.wall,
            artworkFile: hash.map(NowPlayingFeedStore.artworkFileName(forHash:))
        )
        return (feed, hash)
    }

    private func writeWidgetFeed(_ feed: NowPlayingFeed, artworkHash: String?) {
        guard let store = Self.widgetFeedStore else { return }
        do {
            let changed = try store.write(feed) { [artworkService] in
                // The same 480 px thumbnail the system now-playing info uses,
                // so it is usually already cached.
                guard let artworkHash,
                      let image = artworkService.generateThumbnail(artworkHash: artworkHash, size: CGSize(width: 480, height: 480)),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return nil }
                return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }
            if changed {
                WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingFeed.widgetKind)
            }
        } catch {
            AppLog.ui.error("Now Playing widget feed not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
