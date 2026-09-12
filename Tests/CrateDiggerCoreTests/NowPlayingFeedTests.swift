#if canImport(XCTest)
import Foundation
import XCTest
import NowPlayingFeed

final class NowPlayingFeedTests: XCTestCase {

    private var directory: URL!
    private var store: NowPlayingFeedStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingFeedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = NowPlayingFeedStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func playing(art: String? = nil) -> NowPlayingFeed {
        NowPlayingFeed(state: .playing, title: "Song", artist: "Band", album: "Record",
                       duration: 200, playhead: 12, playheadAt: Date(timeIntervalSince1970: 1_000),
                       artworkFile: art)
    }

    private func artFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("art-") }
            .sorted()
    }

    func testNothingWrittenReadsAsIdle() {
        XCTAssertEqual(store.read(), .idle)
    }

    func testAWrittenFeedReadsBack() throws {
        XCTAssertTrue(try store.write(playing(), artwork: { nil }))
        XCTAssertEqual(store.read(), playing())
    }

    func testTheSameFeedIsNotWrittenTwice() throws {
        try store.write(playing(), artwork: { nil })
        let file = directory.appendingPathComponent(NowPlayingFeedStore.feedFileName)
        let past = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

        XCTAssertFalse(try store.write(playing(), artwork: { nil }))
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, past)
    }

    func testArtworkIsWrittenOncePerFile() throws {
        var encodes = 0
        let art = { () -> Data? in encodes += 1; return Data([1, 2, 3]) }

        try store.write(playing(art: "art-a.jpg"), artwork: art)
        var paused = playing(art: "art-a.jpg")
        paused.state = .paused
        try store.write(paused, artwork: art)

        XCTAssertEqual(encodes, 1)
        XCTAssertEqual(try artFiles(), ["art-a.jpg"])
        let url = try XCTUnwrap(store.artworkURL(for: store.read()))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    func testTheOldArtworkGoesWhenTheArtChanges() throws {
        try store.write(playing(art: "art-a.jpg"), artwork: { Data([1]) })
        try store.write(playing(art: "art-b.jpg"), artwork: { Data([2]) })
        XCTAssertEqual(try artFiles(), ["art-b.jpg"])

        try store.write(.idle, artwork: { nil })
        XCTAssertEqual(try artFiles(), [])
    }

    func testMissingArtworkLeavesTheFeedWithoutArt() throws {
        try store.write(playing(art: "art-a.jpg"), artwork: { nil })
        XCTAssertNil(store.read().artworkFile)
        XCTAssertNil(store.artworkURL(for: store.read()))
    }
}
#endif
