import CrateDiggerCore
import Foundation

/// The STATS screen: which window it shows and the cached summary it draws.
///
/// The summary is one pass over the listening store, cheap but not free, so
/// it runs only when both are true: something changed (a counted play, a
/// window change, a store reset) and the screen is the one on the glass. An
/// evening of shuffle on the NOW screen costs zero passes.
@MainActor
extension LibraryViewModel {

    func cycleStatsWindow() {
        statsWindow = statsWindow.next
    }

    /// Something the summary reads has changed. Recomputes at once if the
    /// screen is showing, otherwise waits for it to be shown.
    func markListeningSummaryStale() {
        listeningSummaryIsStale = true
        if oledView == .stats { refreshListeningSummaryIfNeeded() }
    }

    /// Recompute if anything changed since the last pass. Called by the pane
    /// on appear and by `markListeningSummaryStale()` while it is showing.
    func refreshListeningSummaryIfNeeded() {
        guard listeningSummaryIsStale else { return }
        listeningSummaryIsStale = false
        let store = currentTrackStore()
        listeningSummary = ListeningSummary.compute(
            stats: currentListeningStore().allStats,
            window: statsWindow,
            resolve: { store.track(path: $0) }
        )
    }
}
