import XCTest
@testable import CrateDiggerCore

final class StreamSourceCodableTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let s = StreamSource(id: "s1", url: "https://youtube.com/@safeplace", title: "24/7 lofi",
                             channel: "safe place", kind: .live, hue: 18,
                             addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             viewers: "1.4K", durationSeconds: nil)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(StreamSource.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isLive)
    }
}

final class StreamStoreTests: XCTestCase {
    private func freshStore() -> StreamStore {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return StreamStore(prefs: PreferencesStore(defaults: d))
    }

    private func make(_ id: String, _ chan: String, live: Bool = false) -> StreamSource {
        StreamSource(id: id, url: "https://youtube.com/@\(chan)", title: id, channel: chan,
                     kind: live ? .live : .video, hue: 1, addedAt: Date())
    }

    func testAddPrependsAndPersists() {
        let s = freshStore()
        s.add(make("a", "safe place"))
        s.add(make("b", "night drive fm", live: true))
        XCTAssertEqual(s.all().map(\.id), ["b", "a"])
    }

    func testRemove() {
        let s = freshStore()
        s.add(make("a", "x"))
        s.add(make("b", "y"))
        s.remove(id: "a")
        XCTAssertEqual(s.all().map(\.id), ["b"])
    }

    func testChannelsDistinctInOrder() {
        let s = freshStore()
        s.save([make("a", "x"), make("b", "y"), make("c", "x")])
        XCTAssertEqual(s.channels(), ["x", "y"])
    }

    func testLiveChannels() {
        let s = freshStore()
        s.save([make("a", "x", live: true), make("b", "y")])
        XCTAssertEqual(s.liveChannels(), ["x"])
    }

    func testCorruptDataYieldsEmpty() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let prefs = PreferencesStore(defaults: d)
        prefs.streamSourcesData = Data([0x00, 0x01])
        XCTAssertEqual(StreamStore(prefs: prefs).all(), [])
    }

    func testStreamEngineDefaultsToAuto() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        XCTAssertEqual(PreferencesStore(defaults: d).streamEngine, "auto")
    }
}
