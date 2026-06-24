import XCTest
@testable import CrateDiggerCore

final class StreamURLParserTests: XCTestCase {
    func testHandleChannelIsLive() {
        let p = StreamURLParser.parse("https://youtube.com/@safeplace")!
        XCTAssertTrue(p.isValidHost)
        XCTAssertEqual(p.kind, .live)
        XCTAssertEqual(p.channel, "@safeplace")
    }

    func testHandleTitleHumanises() {
        let p = StreamURLParser.parse("https://youtube.com/@night_drive-fm")!
        XCTAssertEqual(p.suggestedTitle, "night drive fm")
    }

    func testPlaylist() {
        let p = StreamURLParser.parse("https://www.youtube.com/playlist?list=PL123")!
        XCTAssertEqual(p.kind, .playlist)
        XCTAssertEqual(p.channel, "Playlist")
    }

    func testWatchWithListIsPlaylist() {
        let p = StreamURLParser.parse("https://www.youtube.com/watch?v=abc&list=PL999")!
        XCTAssertEqual(p.kind, .playlist)
    }

    func testChannelIdTruncated() {
        let p = StreamURLParser.parse("youtube.com/channel/UCabcdefghijklmnopqrstuv")!
        XCTAssertEqual(p.kind, .live)
        XCTAssertTrue(p.channel.hasSuffix("\u{2026}"))
    }

    func testCAndUserPath() {
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/c/NightDrive")!.kind, .live)
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/user/NightDrive")!.channel, "NightDrive")
    }

    func testWatchVideo() {
        let p = StreamURLParser.parse("https://youtube.com/watch?v=abc123")!
        XCTAssertEqual(p.kind, .video)
        XCTAssertEqual(p.channel, "YouTube")
    }

    func testYoutuBeShortVideo() {
        let p = StreamURLParser.parse("https://youtu.be/abc123")!
        XCTAssertEqual(p.kind, .video)
        XCTAssertTrue(p.isValidHost)
    }

    func testLivePath() {
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/@x/live")!.kind, .live)
    }

    func testMissingSchemeStillParses() {
        XCTAssertNotNil(StreamURLParser.parse("youtube.com/@x"))
    }

    func testNonYouTubeHostFlaggedInvalidButClassifies() {
        let p = StreamURLParser.parse("https://vimeo.com/watch?v=1")!
        XCTAssertFalse(p.isValidHost)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(StreamURLParser.parse("not a url at all"))
        XCTAssertNil(StreamURLParser.parse(""))
        XCTAssertNil(StreamURLParser.parse("   "))
    }
}
