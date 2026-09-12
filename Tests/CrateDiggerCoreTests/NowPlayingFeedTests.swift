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

    private func cover(_ file: String) -> NowPlayingFeed.Cover {
        NowPlayingFeed.Cover(file: file, album: "Record \(file)", artist: "Band", year: 1999, crate: "Jazz")
    }

    private func pictures() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.picturesDirectory.path)) ?? []).sorted()
    }

    private let bytesOfName: (String) -> Data? = { Data($0.utf8) }

    // MARK: Store

    func testNothingWrittenReadsAsIdle() {
        XCTAssertEqual(store.read(), .idle)
    }

    func testAWrittenFeedReadsBack() throws {
        var feed = playing()
        feed.lastCover = NowPlayingFeed.Cover(file: "a.jpg", album: "Record", artist: "Band",
                                              playedAt: Date(timeIntervalSince1970: 2_000))
        try store.writePicture(Data([1]), named: "a.jpg")
        XCTAssertTrue(try store.write(feed, picture: { _ in nil }))
        XCTAssertEqual(store.read(), feed)
    }

    func testTheSameFeedIsNotWrittenTwice() throws {
        try store.write(playing(), picture: { _ in nil })
        let file = directory.appendingPathComponent(NowPlayingFeedStore.feedFileName)
        let past = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

        XCTAssertFalse(try store.write(playing(), picture: { _ in nil }))
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, past)
    }

    func testEachPictureIsAskedForOnce() throws {
        var asked: [String] = []
        let bytes = { (name: String) -> Data? in asked.append(name); return Data(name.utf8) }

        try store.write(playing(art: "a.jpg"), picture: bytes)
        var paused = playing(art: "a.jpg")
        paused.state = .paused
        try store.write(paused, picture: bytes)

        XCTAssertEqual(asked, ["a.jpg"])
        let url = try XCTUnwrap(store.pictureURL(named: "a.jpg"))
        XCTAssertEqual(try Data(contentsOf: url), Data("a.jpg".utf8))
    }

    func testEveryNamedPictureIsKeptAndTheRestRemoved() throws {
        var feed = playing(art: "a.jpg")
        feed.slides = ["a.jpg", "p1.jpg"]
        feed.idleSlides = [cover("c1.jpg")]
        feed.lastCover = cover("a.jpg")
        try store.write(feed, picture: bytesOfName)
        XCTAssertEqual(pictures(), ["a.jpg", "c1.jpg", "p1.jpg"])

        feed.slides = []
        try store.write(feed, picture: bytesOfName)
        XCTAssertEqual(pictures(), ["a.jpg", "c1.jpg"])

        try store.write(.idle, picture: bytesOfName)
        XCTAssertEqual(pictures(), [])
    }

    func testAPictureWithNoBytesIsLeftOutOfTheFeed() throws {
        var feed = playing(art: "a.jpg")
        feed.slides = ["a.jpg", "p1.jpg"]
        feed.idleSlides = [cover("c1.jpg")]
        feed.lastCover = cover("old.jpg")
        try store.write(feed, picture: { $0 == "a.jpg" ? Data([1]) : nil })

        let read = store.read()
        XCTAssertEqual(read.artworkFile, "a.jpg")
        XCTAssertEqual(read.slides, ["a.jpg"])
        XCTAssertEqual(read.idleSlides, [])
        XCTAssertNil(read.lastCover)
    }

    func testAPictureRenderedLaterJoinsTheNextWrite() throws {
        var feed = playing()
        feed.idleSlides = [cover("c1.jpg")]
        try store.write(feed, picture: { _ in nil })
        XCTAssertEqual(store.read().idleSlides, [])

        try store.writePicture(Data([1]), named: "c1.jpg")
        XCTAssertTrue(try store.write(feed, picture: { _ in nil }))
        XCTAssertEqual(store.read().idleSlides, [cover("c1.jpg")])
    }

    // MARK: What the widget shows

    func testTheSlideshowFollowsStateAndMode() {
        var feed = NowPlayingFeed(slides: ["a", "p"], idleSlides: [cover("c")])
        XCTAssertEqual(feed.slideshow, ["c"])
        feed.idleMode = .lastAlbumCover
        XCTAssertEqual(feed.slideshow, [])

        feed.state = .playing
        XCTAssertEqual(feed.slideshow, [])
        feed.playingMode = .coverAndBooklet
        XCTAssertEqual(feed.slideshow, ["a", "p"])
        feed.state = .paused
        XCTAssertEqual(feed.slideshow, ["a", "p"])
    }

    func testTheStillPictureFollowsStateAndMode() {
        var feed = NowPlayingFeed(artworkFile: "now", idleMode: .lastAlbumCover, lastCover: cover("last"))
        XCTAssertEqual(feed.stillPicture, "last")
        feed.idleMode = .phrase
        XCTAssertNil(feed.stillPicture)
        feed.state = .paused
        XCTAssertEqual(feed.stillPicture, "now")
    }

    func testAPictureFindsTheWordsThatGoBesideIt() {
        let feed = NowPlayingFeed(idleSlides: [cover("c1"), cover("c2")], lastCover: cover("last"))
        XCTAssertEqual(feed.cover(forPicture: "c2"), cover("c2"))
        XCTAssertEqual(feed.cover(forPicture: "last"), cover("last"))
        XCTAssertNil(feed.cover(forPicture: "elsewhere"))
    }

    func testSlidesMoveOnTheMinuteAndWrap() {
        let minute = Date(timeIntervalSinceReferenceDate: 60 * 1000)
        XCTAssertEqual(NowPlayingFeed.slideIndex(at: minute, count: 3), 1)
        XCTAssertEqual(NowPlayingFeed.slideIndex(at: minute.addingTimeInterval(59), count: 3), 1)
        XCTAssertEqual(NowPlayingFeed.slideIndex(at: minute.addingTimeInterval(60), count: 3), 2)
        XCTAssertEqual(NowPlayingFeed.slideIndex(at: minute.addingTimeInterval(120), count: 3), 0)
        XCTAssertEqual(NowPlayingFeed.slideIndex(at: minute, count: 0), 0)
    }

    func testSlideDatesStartNowThenLandOnMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 60 * 1000 + 25)
        XCTAssertEqual(NowPlayingFeed.slideDates(from: now, count: 3), [
            now,
            Date(timeIntervalSinceReferenceDate: 60 * 1001),
            Date(timeIntervalSinceReferenceDate: 60 * 1002)
        ])
    }
}
#endif
