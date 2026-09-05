import CrateDiggerCore
import Foundation

/// What the mini player's SOURCES panel can start without the full window.
///
/// Each action is the sidebar click plus the shuffle key plus play, in that
/// order, through the same calls those controls make: `selectSource` so the
/// main window is where the music is when you expand, `shuffleEnabled` so
/// `queue(containing:)` deals the crate, and `playTrack` for the rest. Nothing
/// here knows how a queue is built.
@MainActor
extension LibraryViewModel {

    /// Shuffle everything you have scanned.
    func shuffleAllRecords() {
        shuffle(source: .localAll)
    }

    /// Shuffle one crate.
    func shuffleCrate(named name: String) {
        shuffle(source: .localCrate(name: name))
    }

    /// Shuffle one playlist.
    func shufflePlaylist(named name: String) {
        shuffle(source: .playlist(name: name))
    }

    /// Play a saved stream, landing the main window in its radio category.
    func playStream(id: String) {
        guard let stream = streams.first(where: { $0.id == id }) else { return }
        enterRadio(category: RadioCategory.of(stream))
        selectStream(id: id)
    }

    private func shuffle(source: LibrarySource) {
        selectSource(source)
        shuffleEnabled = true
        // Start anywhere: `playTrack` shuffles the browsed set around the
        // chosen track, so the deal is random whichever row we pick.
        guard let opener = browsingTracks.randomElement() else { return }
        playTrack(id: opener.track.id)
    }
}
