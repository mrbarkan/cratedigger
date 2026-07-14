import AppKit
import MediaPlayer
import CrateDiggerCore

/// Bridges playback to macOS system media: hardware media keys (F7/F8/F9),
/// AirPods gestures, Control Center, and the lock-screen "Now Playing" widget.
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
    }
}
