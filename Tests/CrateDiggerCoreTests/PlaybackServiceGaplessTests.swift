#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The look-ahead that makes a track boundary gapless: the service tells the
/// engine what plays next while the current track is still going, and when the
/// engine hands over by itself the service only moves its bookkeeping instead
/// of reloading.
final class PlaybackServiceGaplessTests: XCTestCase {

    // MARK: - What gets prepared

    func testPreparesTheFollowingTrackOnceTheCurrentOneIsReady() async {
        let (service, engine, queue) = await playingService(trackCount: 3)

        XCTAssertEqual(engine.preparedURL, queue[1].url)
        XCTAssertEqual(service.currentIndex, 0)
    }

    func testPreparesNothingWhilePaused() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = localQueue(count: 2)

        service.load(queue: queue, startIndex: 0, autoPlay: false)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(service.state, .paused)
        XCTAssertNil(engine.preparedURL, "a paused deck should not buffer ahead")
    }

    func testPreparesTheFollowingTrackWhenPlaybackStartsFromPaused() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = localQueue(count: 2)

        service.load(queue: queue, startIndex: 0, autoPlay: false)
        engine.simulateReady()
        await pumpMainQueue()
        service.play()

        XCTAssertEqual(engine.preparedURL, queue[1].url)
    }

    func testPreparesNothingOnTheLastTrackWithRepeatOff() async {
        let (service, engine, _) = await playingService(trackCount: 2, startIndex: 1)

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertNil(engine.preparedURL)
    }

    func testRepeatOnePreparesTheSameTrack() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = localQueue(count: 2)
        service.repeatMode = .one

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(engine.preparedURL, queue[0].url,
                       "repeat one should loop the same track without a gap")
    }

    func testRepeatAllPreparesTheFirstTrackFromTheLast() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = localQueue(count: 3)
        service.repeatMode = .all

        service.load(queue: queue, startIndex: 2, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(engine.preparedURL, queue[0].url)
    }

    func testChangingRepeatModeRePreparesImmediately() async {
        let (service, engine, queue) = await playingService(trackCount: 2, startIndex: 1)
        XCTAssertNil(engine.preparedURL)

        service.repeatMode = .all

        XCTAssertEqual(engine.preparedURL, queue[0].url)
    }

    // MARK: - The look-ahead follows queue edits

    func testPlayNextRePreparesTheTrackItJumpedAhead() async {
        let (service, engine, queue) = await playingService(trackCount: 2)
        XCTAssertEqual(engine.preparedURL, queue[1].url)

        let jumped = item(named: "jumped")
        service.insertNext([jumped])

        XCTAssertEqual(engine.preparedURL, jumped.url)
    }

    func testPlayLastDoesNotDisturbAnAlreadyPreparedTrack() async {
        let (service, engine, queue) = await playingService(trackCount: 2)

        service.appendLast([item(named: "last")])

        XCTAssertEqual(engine.preparedURL, queue[1].url)
    }

    func testAppendingToASingleTrackQueuePreparesTheAppendedTrack() async {
        let (service, engine, _) = await playingService(trackCount: 1)
        XCTAssertNil(engine.preparedURL)

        let appended = item(named: "appended")
        service.appendLast([appended])

        XCTAssertEqual(engine.preparedURL, appended.url)
    }

    func testRemovingTheFollowingTrackPreparesTheOneAfterIt() async {
        let (service, engine, queue) = await playingService(trackCount: 3)
        XCTAssertEqual(engine.preparedURL, queue[1].url)

        service.removeFromQueue(at: IndexSet(integer: 1))

        XCTAssertEqual(engine.preparedURL, queue[2].url)
    }

    func testMovingATrackIntoTheNextSlotPreparesIt() async {
        let (service, engine, queue) = await playingService(trackCount: 3)
        XCTAssertEqual(engine.preparedURL, queue[1].url)

        service.moveInQueue(from: 2, to: 1)

        XCTAssertEqual(engine.preparedURL, queue[2].url)
    }

    // MARK: - The advance itself

    func testGaplessAdvanceMovesTheIndexWithoutReloading() async {
        let (service, engine, _) = await playingService(trackCount: 2)
        let playsBefore = engine.playCalls
        let replacementsBefore = engine.replacedURLs.count

        var states: [PlaybackState] = []
        var indices: [Int?] = []
        service.onStateChange = { states.append($0) }
        service.onCurrentIndexChange = { indices.append($0) }

        engine.durationSeconds = 222
        engine.simulateGaplessAdvance()
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .playing)
        XCTAssertFalse(states.contains(.loading), "a gapless advance never reloads")
        XCTAssertEqual(indices, [1], "exactly one index change, so one scrobble")
        XCTAssertEqual(engine.replacedURLs.count, replacementsBefore,
                       "the engine already holds the item; nothing is replaced")
        XCTAssertEqual(engine.playCalls, playsBefore, "audio never stopped")
        XCTAssertEqual(service.currentTimeSeconds, 0)
        XCTAssertEqual(service.durationSeconds, 222)
    }

    func testGaplessAdvancePreparesTheTrackAfterIt() async {
        let (service, engine, queue) = await playingService(trackCount: 3)

        engine.simulateGaplessAdvance()
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(engine.preparedURL, queue[2].url)
    }

    func testGaplessAdvanceOffTheEndOfTheQueueStillEnds() async {
        let (service, engine, _) = await playingService(trackCount: 2)
        engine.simulateGaplessAdvance()
        await pumpMainQueue()

        // Last track now; nothing was prepared, so the engine reports a plain end.
        engine.simulateEnd()
        await pumpMainQueue()

        XCTAssertEqual(service.state, .ended)
        XCTAssertEqual(service.currentIndex, 1)
    }

    func testEndWithoutLookAheadStillReloadsTheNextTrack() async {
        let (service, engine, queue) = await playingService(trackCount: 2)

        // An engine that never looked ahead reports the old-style end.
        engine.simulateEnd()
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)
    }

    // MARK: - What must never be prepared

    func testDoesNotPrepareADSDTrack() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [item(named: "a"), item(named: "b", ext: "dsf")]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertNil(engine.preparedURL, "DSD routes to another engine or a decode")
    }

    func testDoesNotPrepareARemoteStream() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            item(named: "a"),
            PlaybackQueueItem(url: URL(string: "https://example.com/live.m3u8")!,
                              title: "Live", artist: "", album: "", durationSeconds: 0)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertNil(engine.preparedURL, "radio keeps the reload path")
    }

    // MARK: - The off-switch

    func testGaplessDisabledPreparesNothing() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        service.gaplessEnabled = false
        let queue = localQueue(count: 2)

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(service.state, .playing)
        XCTAssertNil(engine.preparedURL)
    }

    func testTurningGaplessOffMidTrackDropsThePreparedTrack() async {
        let (service, engine, queue) = await playingService(trackCount: 2)
        XCTAssertEqual(engine.preparedURL, queue[1].url)

        service.gaplessEnabled = false

        XCTAssertTrue(engine.lookAheadWasCleared)
    }

    func testGaplessDisabledStillAdvancesByReloading() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        service.gaplessEnabled = false
        let queue = localQueue(count: 2)
        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        engine.simulateEnd()
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)
    }

    // MARK: - Flushing a stale look-ahead

    func testManualNextClearsThePreparedTrack() async {
        let (service, engine, _) = await playingService(trackCount: 3)

        service.next()

        XCTAssertTrue(engine.lookAheadWasCleared,
                      "the look-ahead is dropped before the new track loads")
    }

    func testLoadingAnEmptyQueueClearsThePreparedTrack() async {
        let (service, engine, _) = await playingService(trackCount: 2)

        service.load(queue: [], startIndex: 0, autoPlay: false)

        XCTAssertTrue(engine.lookAheadWasCleared)
    }

    // MARK: - Helpers

    private func item(named name: String, ext: String = "flac") -> PlaybackQueueItem {
        PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/\(name).\(ext)"),
                          title: name, artist: "Artist", album: "Album",
                          durationSeconds: 100)
    }

    private func localQueue(count: Int) -> [PlaybackQueueItem] {
        (0..<count).map { item(named: "track\($0)") }
    }

    /// A service playing `startIndex` of a local queue, ready and past its
    /// first look-ahead.
    private func playingService(
        trackCount: Int,
        startIndex: Int = 0
    ) async -> (PlaybackService, MockPlaybackEngine, [PlaybackQueueItem]) {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = localQueue(count: trackCount)
        service.load(queue: queue, startIndex: startIndex, autoPlay: true)
        engine.durationSeconds = 100
        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)
        return (service, engine, queue)
    }
}
#endif
