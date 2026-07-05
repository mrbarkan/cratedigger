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

    // A share URL that names a specific video is that video, even with a
    // &list= context — otherwise the resolver plays the playlist's first item.
    func testWatchWithListIsVideo() {
        let p = StreamURLParser.parse("https://www.youtube.com/watch?v=abc&list=PL999")!
        XCTAssertEqual(p.kind, .video)
    }

    func testShortLinkWithListIsVideo() {
        let p = StreamURLParser.parse("https://youtu.be/abc123?list=PL999")!
        XCTAssertEqual(p.kind, .video)
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

    func testLookAlikeHostRejectedSubdomainAccepted() {
        XCTAssertFalse(StreamURLParser.parse("https://fakeyoutube.com/watch?v=1")!.isValidHost)
        XCTAssertFalse(StreamURLParser.parse("https://notyoutu.be/abc")!.isValidHost)
        XCTAssertTrue(StreamURLParser.parse("https://music.youtube.com/watch?v=1")!.isValidHost)
    }

    func testNormalizedURLGetsScheme() {
        XCTAssertEqual(StreamURLParser.parse("youtube.com/@x")!.normalizedURL, "https://youtube.com/@x")
        XCTAssertEqual(StreamURLParser.parse(" https://youtu.be/abc \n")!.normalizedURL, "https://youtu.be/abc")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(StreamURLParser.parse("not a url at all"))
        XCTAssertNil(StreamURLParser.parse(""))
        XCTAssertNil(StreamURLParser.parse("   "))
    }
}
