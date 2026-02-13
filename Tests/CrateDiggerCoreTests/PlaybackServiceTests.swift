#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaybackServiceTests: XCTestCase {
    func testLoadAutoPlayTransitionsLoadingToPlaying() {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)

        let firstURL = URL(fileURLWithPath: "/tmp/a.flac")
        let queue = [PlaybackQueueItem(url: firstURL, title: "A", artist: "AA", album: "AB", durationSeconds: 120)]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(service.currentIndex, 0)

        engine.durationSeconds = 120
        engine.simulateReady()
        pumpMainRunLoop()

        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(service.durationSeconds, 120)
        XCTAssertEqual(engine.playCalls, 1)
    }

    func testPauseAndResumeFromPlaying() {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.durationSeconds = 100
        engine.simulateReady()
        pumpMainRunLoop()
        XCTAssertEqual(service.state, .playing)

        service.pause()
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(engine.pauseCalls, 1)

        service.play()
        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(engine.playCalls, 2)
    }

    func testQueueNavigationAndEndedState() {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100),
            PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/b.flac"), title: "B", artist: "", album: "", durationSeconds: 120)
        ]

        service.load(queue: queue, startIndex: 0, autoPlay: true)
        engine.simulateReady()
        pumpMainRunLoop()
        XCTAssertEqual(service.currentIndex, 0)

        service.next()
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)

        engine.simulateReady()
        pumpMainRunLoop()
        XCTAssertEqual(service.state, .playing)

        service.next()
        XCTAssertEqual(service.state, .ended)
        XCTAssertEqual(service.currentIndex, 1)
    }

    func testSeekClampsToDuration() {
        let engine = MockPlaybackEngine()
        let service = PlaybackService(engine: engine)
        let queue = [PlaybackQueueItem(url: URL(fileURLWithPath: "/tmp/a.flac"), title: "A", artist: "", album: "", durationSeconds: 100)]

        service.load(queue: queue, startIndex: 0, autoPlay: false)
        engine.durationSeconds = 100
        engine.simulateReady()
        pumpMainRunLoop()

        service.seek(toSeconds: 999)
        XCTAssertEqual(engine.lastSeek, 100, accuracy: 0.001)
        XCTAssertEqual(service.currentTimeSeconds, 100, accuracy: 0.001)
    }

    func testFailureSkipsToNextTrackWhenAvailable() {
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
        pumpMainRunLoop()

        XCTAssertEqual(errorMessage, "Corrupt file")
        XCTAssertEqual(service.currentIndex, 1)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(engine.replacedURLs.last, queue[1].url)

        engine.simulateReady()
        pumpMainRunLoop()
        XCTAssertEqual(service.state, .playing)
    }

    private func pumpMainRunLoop() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
    }
}

private final class MockPlaybackEngine: PlaybackEngineProtocol {
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
