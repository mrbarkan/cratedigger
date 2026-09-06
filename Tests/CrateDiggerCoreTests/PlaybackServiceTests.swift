#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaybackServiceTests: XCTestCase {
    func testLoadAutoPlayTransitionsLoadingToPlaying() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)

        let firstURL = URL(fileURLWithPath: "/tmp/a.flac")
        let queue = [PlaybackQueueItem(url: firstURL, title: "A", artist: "AA", album: "AB", durationSeconds: 120)]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(service.currentIndex, 0)

        engine.durationSeconds = 120
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(service.durationSeconds, 120)
        XCTAssertEqual(engine.playCalls, 1)
    }

    func testPauseAndResumeFromPlaying() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.durationSeconds = 100
        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)

        service.pause()
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(engine.pauseCalls, 1)

        service.play()
        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(engine.playCalls, 2)
    }

    func testQueueNavigationAndEndedState() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.currentIndex, 0)

        service.next()
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)

        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)

        service.next()
        XCTAssertEqual(service.state, .ended)
        XCTAssertEqual(service.currentIndex, 1)
    }

    func testSeekClampsToDuration() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)]

        service.load(queue: queue, startIndex: 0, autoPlay: false)
        engine.durationSeconds = 100
        engine.simulateReady()
        await pumpMainQueue()

        service.seek(toSeconds: 999)
        XCTAssertEqual(engine.lastSeek, 100, accuracy: 0.001)
        XCTAssertEqual(service.currentTimeSeconds, 100, accuracy: 0.001)
    }

    func testRepeatOneReplaysSameIndexOnItemEnd() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.repeatMode = .one
        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)

        engine.simulateEnd()
        XCTAssertEqual(service.currentIndex, 0)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[0].url)

        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)
    }

    func testRepeatAllWrapsFromLastToFirstOnItemEnd() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.repeatMode = .all
        service.load(queue: queue, startIndex: 1, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.currentIndex, 1)

        engine.simulateEnd()
        XCTAssertEqual(service.currentIndex, 0)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[0].url)

        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)
    }

    func testRepeatAllAdvancesNormallyMidQueue() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.repeatMode = .all
        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        engine.simulateEnd()
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)
    }

    func testRepeatOffStillEndsAtQueueEnd() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)
        ]

        service.repeatMode = .off
        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.durationSeconds = 100
        engine.simulateReady()
        await pumpMainQueue()

        engine.simulateEnd()
        XCTAssertEqual(service.state, .ended)
        XCTAssertEqual(service.currentIndex, 0)
    }

    func testFailureSkipsToNextTrackWhenAvailable() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/bad.flac"), title: "Bad", artist: "", album: "", durationSeconds: 10),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/good.flac"), title: "Good", artist: "", album: "", durationSeconds: 20)
        ]

        var errorMessage: String?
        service.onError = { errorMessage = $0 }

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateFailure("Corrupt file")
        await pumpMainQueue()

        XCTAssertEqual(errorMessage, "Corrupt file")
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)

        engine.simulateReady()
        await pumpMainQueue()
        XCTAssertEqual(service.state, .playing)
    }

    // MARK: - Queue editing (Play Next / Play Last)

    private func item(_ name: String) -> PlaybackQueueItem {
        PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/\(name).flac"),
                          title: name, artist: "", album: "", durationSeconds: 60)
    }

    private func loadedService(_ names: [String], startIndex: Int = 0) async -> (PlaybackService, MockPlaybackEngine) {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        service.load(queue: names.map(item), startIndex: startIndex, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()
        return (service, engine)
    }

    func testPlayNextInsertsAfterTheCurrentTrack() async {
        let (service, engine) = await loadedService(["A", "B", "C"], startIndex: 1)
        let before = engine.replacedURLs.count

        service.insertNext([item("X")])

        XCTAssertEqual(service.queue.map(\.title), ["A", "B", "X", "C"])
        XCTAssertEqual(service.currentIndex, 1, "the playing track must not move")
        XCTAssertEqual(engine.replacedURLs.count, before, "queueing must not touch the engine")
        XCTAssertEqual(service.state, .playing)
    }

    func testPlayLastAppendsToTheEnd() async {
        let (service, _) = await loadedService(["A", "B"], startIndex: 0)
        service.appendLast([item("Y"), item("Z")])
        XCTAssertEqual(service.queue.map(\.title), ["A", "B", "Y", "Z"])
        XCTAssertEqual(service.currentIndex, 0)
    }

    /// With nothing playing there is no "next", so it lands at the front.
    func testPlayNextWithEmptyQueueSeedsTheQueue() {
        let service = PlaybackService(engine: MockPlaybackEngine())
        service.insertNext([item("A")])
        XCTAssertEqual(service.queue.map(\.title), ["A"])
    }

    func testUpNextIsEverythingAfterTheCurrentTrack() async {
        let (service, _) = await loadedService(["A", "B", "C"], startIndex: 1)
        XCTAssertEqual(service.upNext.map(\.title), ["C"])
        service.insertNext([item("X")])
        XCTAssertEqual(service.upNext.map(\.title), ["X", "C"])
    }

    func testQueuedTrackPlaysNextWhenTheCurrentOneEnds() async {
        let (service, engine) = await loadedService(["A", "B"], startIndex: 0)
        service.insertNext([item("X")])
        engine.simulateEnd()
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(engine.replacedURLs.last, URL(fileURLWithPath: "/tmp/X.flac"))
    }

    func testRemoveFromQueueKeepsCurrentIndexOnTheSameTrack() async {
        let (service, _) = await loadedService(["A", "B", "C", "D"], startIndex: 2)
        let removed = service.removeFromQueue(at: IndexSet([0, 1]))
        XCTAssertEqual(removed, IndexSet([0, 1]))
        XCTAssertEqual(service.queue.map(\.title), ["C", "D"])
        XCTAssertEqual(service.currentIndex, 0, "still pointing at C")
    }

    func testRemoveFromQueueRefusesToRemoveThePlayingTrack() async {
        let (service, _) = await loadedService(["A", "B", "C"], startIndex: 1)
        let removed = service.removeFromQueue(at: IndexSet([1, 2]))
        XCTAssertEqual(removed, IndexSet([2]))
        XCTAssertEqual(service.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(service.currentIndex, 1)
    }

    /// Re-pointing the index after a queue edit must NOT read as a track change,
    /// or the playing track's scrobble progress resets every time you queue.
    func testQueueEditDoesNotReportATrackChange() async {
        let (service, _) = await loadedService(["A", "B", "C"], startIndex: 2)
        var indexChanges = 0
        service.onCurrentIndexChange = { _ in indexChanges += 1 }

        service.removeFromQueue(at: IndexSet([0]))
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(indexChanges, 0, "same track, only a different position")
    }

    func testMoveInQueueKeepsCurrentIndexOnTheSameTrack() async {
        let (service, _) = await loadedService(["A", "B", "C", "D"], startIndex: 2)
        service.moveInQueue(from: 0, to: 4)          // A to the end
        XCTAssertEqual(service.queue.map(\.title), ["B", "C", "D", "A"])
        XCTAssertEqual(service.currentIndex, 1, "still C")

        service.moveInQueue(from: 3, to: 0)          // A back to the front
        XCTAssertEqual(service.queue.map(\.title), ["A", "B", "C", "D"])
        XCTAssertEqual(service.currentIndex, 2, "still C")
    }

    func testMoveInQueueRefusesToMoveThePlayingTrack() async {
        let (service, _) = await loadedService(["A", "B", "C"], startIndex: 1)
        service.moveInQueue(from: 1, to: 0)
        XCTAssertEqual(service.queue.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(service.currentIndex, 1)
    }

    /// Pressing Next on the last track under Repeat All must wrap, exactly like
    /// letting that track play out does.
    func testRepeatAllWrapsFromLastToFirstOnManualNext() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.repeatMode = .all
        service.load(queue: queue, startIndex: 1, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        service.next()
        XCTAssertEqual(service.currentIndex, 0)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[0].url)
    }

    /// Repeat Off keeps the old behaviour: Next on the last track ends the queue.
    func testRepeatOffStillEndsOnManualNextAtQueueEnd() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        service.next()
        XCTAssertEqual(service.state, .ended)
    }

    /// Pressing Previous at the head of the queue under Repeat All wraps to the
    /// last track (past the 3s "restart this track" window).
    func testRepeatAllWrapsFromFirstToLastOnManualPrevious() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.repeatMode = .all
        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        service.previous()
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)
    }

    /// Repeat Off keeps the old behaviour: Previous at the head restarts track 1.
    func testRepeatOffPreviousAtQueueHeadRestartsTrack() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        await pumpMainQueue()

        service.previous()
        XCTAssertEqual(service.currentIndex, 0)
        XCTAssertEqual(engine.lastSeek, 0)
    }

    /// A file that fails to load while the user has NOT pressed play must skip
    /// on without starting playback by itself.
    func testFailureWhilePausedSkipsOnWithoutStartingPlayback() async {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/bad.flac"), title: "Bad", artist: "", album: "", durationSeconds: 10),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/good.flac"), title: "Good", artist: "", album: "", durationSeconds: 20)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: false)
        engine.simulateFailure("Corrupt file")
        await pumpMainQueue()
        engine.simulateReady()
        await pumpMainQueue()

        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(engine.playCalls, 0)
    }

    /// Volume set while the native (DoP) engine is active must still reach the
    /// AVPlayer engine, or a fallback to PCM plays at a stale level.
    func testVolumeReachesBothEnginesRegardlessOfWhichIsActive() async {
        let engine = MockPlaybackEngine()
        let native = MockPlaybackEngine()
        let service = PlaybackService(engine: engine, nativeDSDEngine: native)

        service.setVolume(0.25)
        XCTAssertEqual(engine.volume, 0.25)
        XCTAssertEqual(native.volume, 0.25)
    }
}

final class MockPlaybackEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?

    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    var replacedURLs: [URL] = []
    var playCalls = 0
    var pauseCalls = 0
    var lastSeek: Double = 0
    var volume: Double = 1

    func replaceCurrentItem(url: URL) {
        replacedURLs.append(url)
        currentTimeSeconds = 0
    }

    func play() {
        playCalls += 1
    }

    func pause() {
        pauseCalls += 1
    }

    func seek(toSeconds: Double) {
        lastSeek = toSeconds
        currentTimeSeconds = toSeconds
    }

    func setVolume(_ volume: Double) {
        self.volume = volume
    }

    func setOutputDeviceUID(_ uid: String?) {
        // No-op for mock
    }

    /// Every value `prepareNextItem` was handed, in order — nil entries are
    /// the look-ahead being cleared.
    var preparedURLs: [URL?] = []
    /// What is prepared right now: the last value handed over, or nil if none.
    var preparedURL: URL? { preparedURLs.last ?? nil }
    private(set) var didAdvanceGaplessly = false
    /// True when the most recent look-ahead call cleared it, as opposed to
    /// setting one or never having been called at all.
    var lookAheadWasCleared: Bool {
        guard let last = preparedURLs.last else { return false }
        return last == nil
    }

    func prepareNextItem(url: URL?) {
        preparedURLs.append(url)
    }

    /// The prepared item taking over from the one that ended, which is what a
    /// real AVQueuePlayer does by itself. The flag is only true for the length
    /// of the callback, exactly as the engine sets it.
    func simulateGaplessAdvance() {
        didAdvanceGaplessly = true
        onItemEnded?()
        didAdvanceGaplessly = false
    }

    func simulateReady() {
        onItemReady?()
    }

    func simulateFailure(_ message: String) {
        onItemFailed?(message)
    }

    func simulateEnd() {
        onItemEnded?()
    }

    func simulateTime(current: Double, duration: Double) {
        currentTimeSeconds = current
        durationSeconds = duration
        onPeriodicTime?(current, duration)
    }
}
#endif
