import XCTest
@testable import CrateDiggerCore

private final class FakeEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    private(set) var replacedURLs: [URL] = []
    func replaceCurrentItem(url: URL) { replacedURLs.append(url) }
    func play() {}
    func pause() {}
    func seek(toSeconds: Double) {}
    func setVolume(_ volume: Double) {}
    func setOutputDeviceUID(_ uid: String?) {}
}

/// Decoder whose completion we fire manually, to exercise the async seam.
private final class ManualDecoder: DSDPlaybackDecoding {
    var pending: ((Result<URL, Error>) -> Void)?
    let tempURL = URL(fileURLWithPath: "/tmp/decoded.caf")
    func canDecode(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dsf" }
    func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) { pending = completion }
    func fireSuccess() { pending?(.success(tempURL)); pending = nil }
}

private func item(_ path: String) -> PlaybackQueueItem {
    PlaybackQueueItem(url: URL(fileURLWithPath: path), title: "t", artist: "a", album: "b", durationSeconds: 100)
}

final class PlaybackServiceDSDTests: XCTestCase {
    func testNonDSDLoadsDirectly() {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/song.flac")], startIndex: 0, autoPlay: false)
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/song.flac")])
    }

    func testDSDDecodesBeforeReplacingItem() async {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/song.dsf")], startIndex: 0, autoPlay: false)
        // Nothing handed to the engine until decode finishes.
        XCTAssertTrue(engine.replacedURLs.isEmpty)
        decoder.fireSuccess()
        // The completion hops to the main queue (real decodes land on a
        // background queue) — pump it, matching the convention other
        // PlaybackService tests in this target use.
        await pumpMainQueue()
        XCTAssertEqual(engine.replacedURLs, [decoder.tempURL])
    }

    func testStaleDecodeIsDropped() {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/a.dsf"), item("/x/b.flac")], startIndex: 0, autoPlay: false)
        let staleCompletion = decoder.pending          // decode of a.dsf in flight
        svc.next()                                      // user skips to b.flac
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/b.flac")])
        staleCompletion?(.success(decoder.tempURL))     // a.dsf decode lands late
        // The late decode must NOT replace the now-current flac.
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/b.flac")])
    }
}
