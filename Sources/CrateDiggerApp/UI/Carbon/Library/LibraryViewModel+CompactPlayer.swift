import CrateDiggerCore
import Foundation

/// The compact player: the main window folded down to art, display and
/// transport. The layout is one published value; the window controller and
/// `CarbonRootView` follow it, so every route in and out (menu, expand key,
/// zoom button, a sheet that needs room) is just a write to it.
@MainActor
extension LibraryViewModel {

    var isCompactPlayer: Bool { playerLayout == .compact }

    func toggleCompactPlayer() {
        playerLayout = isCompactPlayer ? .full : .compact
    }

    func expandToFull() {
        guard isCompactPlayer else { return }
        playerLayout = .full
    }

    /// The album the art well opens in the artwork viewer. Nil for a stream,
    /// a remote track, or a track the browsed index does not hold — the art
    /// is not clickable then. `album(containing:)` returns a grouped release's
    /// member pressing, which is the right one for artwork.
    var nowPlayingAlbum: Album? {
        guard !isStreamActive, let playing = nowPlayingTrack else { return nil }
        return album(containing: playing.track.id)
    }

    /// Same route as the browser's View Artwork: the presenter (hoisted to
    /// `LibraryPresentations`) picks the booklet reader or the navigator.
    func showNowPlayingArtwork() {
        guard let album = nowPlayingAlbum else { return }
        artworkViewerAlbum = album
    }
}
