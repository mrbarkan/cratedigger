#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

private final class SpyEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    private(set) var replacedURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    func replaceCurrentItem(url: URL) { replacedURLs.append(url) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(toSeconds seconds: Double) { seeks.append(seconds) }
    func setVolume(_ volume: Double) {}
    func setOutputDeviceUID(_ uid: String?) {}
}

/// Minimal stereo DSD64 DSF so DSFFile.readInfo succeeds during routing.
private func dsfFixture() throws -> URL {
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: "DSD ".utf8); le64(28); le64(UInt64(92 + 8192)); le64(0)
    data.append(contentsOf: "fmt ".utf8); le64(52); le32(1); le32(0); le32(2); le32(2)
    le32(2_822_400); le32(1); le64(4096 * 8); le32(4096); le32(0)
    data.append(contentsOf: "data".utf8); le64(12 + 8192)
    data.append(Data(repeating: 0x69, count: 8192))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("route-\(UUID().uuidString).dsf")
    try data.write(to: url)
    return url
}

final class PlaybackServiceDoPTests: XCTestCase {
    private func makeService(rates: [Double]) throws -> (PlaybackService, SpyEngine, SpyEngine, URL) {
        let av = SpyEngine()
        let native = SpyEngine()
        let dsf = try dsfFixture()
        let service = PlaybackService(engine: av, decoder: nil, nativeDSDEngine: native,
                                      deviceRatesProvider: { _ in rates })
        return (service, av, native, dsf)
    }

    private func item(_ url: URL) -> PlaybackQueueItem {
        PlaybackQueueItem(url: url, title: "t", artist: "a", album: "b", durationSeconds: 10)
    }

    func testDSFRoutesToNativeEngineWhenDeviceSupportsRate() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.load(queue: [item(dsf)], startIndex: 0, autoPlay: false)
        XCTAssertEqual(native.replacedURLs, [dsf], "raw DSF goes to the native engine")
        XCTAssertTrue(av.replacedURLs.isEmpty)
        XCTAssertTrue(service.isNativeDSDActive)
    }

    func testDSFFallsBackToAVEngineWhenDeviceLacksRate() throws {
        let (service, av, native, dsf) = try makeService(rates: [44_100, 48_000])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.load(queue: [item(dsf)], startIndex: 0, autoPlay: false)
        // No decoder injected → the DSF goes to the AV engine directly (the
        // decode path itself is exercised by PlaybackServiceDSDTests).
        XCTAssertEqual(av.replacedURLs, [dsf])
        XCTAssertTrue(native.replacedURLs.isEmpty)
        XCTAssertFalse(service.isNativeDSDActive)
    }

    func testPCMModeNeverRoutesNative() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.dsdOutputMode = .pcm
        service.load(queue: [item(dsf)], startIndex: 0, autoPlay: false)
        XCTAssertEqual(av.replacedURLs, [dsf])
        XCTAssertTrue(native.replacedURLs.isEmpty)
    }

    func testTransportForwardsToActiveEngineAndSwitchPausesOther() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        let flac = URL(fileURLWithPath: "/x/song.flac")
        service.load(queue: [item(dsf), item(flac)], startIndex: 0, autoPlay: false)
        service.play()
        XCTAssertEqual(native.playCount, 1)
        XCTAssertEqual(av.playCount, 0)
        service.seek(toSeconds: 3)
        XCTAssertEqual(native.seeks, [3])

        service.next()   // flac → AV engine becomes active, native pauses
        XCTAssertEqual(av.replacedURLs, [flac])
        XCTAssertGreaterThanOrEqual(native.pauseCount, 1)
        XCTAssertFalse(service.isNativeDSDActive)
        service.play()
        XCTAssertEqual(av.playCount, 1)
    }

    func testNativeFailureFallsBackToPCMPathOnce() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.load(queue: [item(dsf)], startIndex: 0, autoPlay: false)
        XCTAssertEqual(native.replacedURLs, [dsf])
        // Native engine reports failure (e.g. device refused the rate).
        native.onItemFailed?("no lock")
        // The SAME track retries through the PCM path on the AV engine.
        XCTAssertEqual(av.replacedURLs, [dsf])
        XCTAssertFalse(service.isNativeDSDActive)
    }
}
#endif
