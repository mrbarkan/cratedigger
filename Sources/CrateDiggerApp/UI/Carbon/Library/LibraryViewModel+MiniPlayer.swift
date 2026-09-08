import CrateDiggerCore
import Foundation

/// What the mini player's SOURCES panel can start without the full window.
///
/// Each action is the sidebar click plus the shuffle key plus play, in that
/// order, through the same calls those controls make: `selectSource` so the
/// main window is where the music is when you expand, `shuffleEnabled` so the
/// transport reads as shuffling, and `startQueue` for the rest.
@MainActor
extension LibraryViewModel {

    /// One tap deals this many tracks, and ADD MORE deals another hand.
    ///
    /// The deal used to be `browsingTracks`, which is the browser's *leaf* —
    /// whatever artist or album the columns happened to be anchored on. Tapping
    /// a crate therefore queued three tracks or three thousand depending on
    /// where you had last clicked in a window you weren't even looking at. A
    /// fixed hand off the whole source is predictable, and topping it up is a
    /// tap rather than a decision.
    static let shuffleDealSize = 20

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
        let deal = Array(index.allTracks.shuffled().prefix(Self.shuffleDealSize))
        guard !deal.isEmpty else { return }
        startQueue(deal, at: 0)
    }

    /// Tracks in the playing source that the current queue doesn't hold yet.
    /// Only offered while the browsed source *is* the playing one: the deal
    /// comes out of `index`, and after navigating elsewhere that is a different
    /// record box than the one on the deck.
    var shuffleDealMoreCount: Int {
        guard shuffleEnabled, playingSource == currentSource, !playbackQueue.isEmpty else { return 0 }
        let queued = Set(playbackQueue.map { $0.track.fileURL.path })
        return index.allTracks.filter { !queued.contains($0.track.fileURL.path) }.count
    }

    /// Deal another hand from the same source, behind what's already queued.
    func dealMoreShuffled() {
        guard shuffleDealMoreCount > 0 else { return }
        let queued = Set(playbackQueue.map { $0.track.fileURL.path })
        let more = index.allTracks
            .filter { !queued.contains($0.track.fileURL.path) }
            .shuffled()
            .prefix(Self.shuffleDealSize)
        playLast(Array(more))
    }
}
