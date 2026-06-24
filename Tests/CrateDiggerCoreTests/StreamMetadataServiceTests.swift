import XCTest
@testable import CrateDiggerCore

final class StreamMetadataServiceTests: XCTestCase {
    func testYtDlpArguments() {
        let args = StreamMetadataService.ytdlpArguments(url: "https://youtu.be/x")
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertTrue(args.contains("--print"))
        XCTAssertEqual(args.last, "https://youtu.be/x")
    }

    func testParseYtDlpVideo() {
        // tab-separated, positional: title, uploader, thumb, dur, is_live, views, cviews
        let line = "chill man\tsafe place\thttps://i.ytimg.com/vi/x/hq.jpg\t3846\tFalse\t2023\tNA"
        let m = StreamMetadataService.parseYtDlp(line)
        XCTAssertEqual(m.title, "chill man")
        XCTAssertEqual(m.channel, "safe place")
        XCTAssertEqual(m.thumbnailURL, "https://i.ytimg.com/vi/x/hq.jpg")
        XCTAssertEqual(m.durationSeconds, 3846)
        XCTAssertEqual(m.isLive, false)
        XCTAssertEqual(m.viewers, "2.0K")     // from view_count
    }

    func testParseYtDlpLivePrefersConcurrentViewers() {
        let line = "lofi radio\tLofi Girl\thttps://i.ytimg.com/vi/y/hq.jpg\tNA\tTrue\t999\t13602"
        let m = StreamMetadataService.parseYtDlp(line)
        XCTAssertEqual(m.isLive, true)
        XCTAssertNil(m.durationSeconds)            // "NA"
        XCTAssertEqual(m.viewers, "13.6K")         // concurrent_view_count preferred for live
    }

    func testParseOEmbed() throws {
        let json = """
        {"title":"chill man","author_name":"safe place","thumbnail_url":"https://i.ytimg.com/vi/x/hq.jpg"}
        """.data(using: .utf8)!
        let m = StreamMetadataService.parseOEmbed(json)!
        XCTAssertEqual(m.title, "chill man")
        XCTAssertEqual(m.channel, "safe place")
        XCTAssertEqual(m.thumbnailURL, "https://i.ytimg.com/vi/x/hq.jpg")
    }

    func testFormatViewCount() {
        XCTAssertNil(StreamMetadataService.formatViewCount(nil))
        XCTAssertEqual(StreamMetadataService.formatViewCount(842), "842")
        XCTAssertEqual(StreamMetadataService.formatViewCount(13602), "13.6K")
        XCTAssertEqual(StreamMetadataService.formatViewCount(2_400_000), "2.4M")
    }

    func testOEmbedURL() {
        let u = StreamMetadataService.oEmbedURL(for: "https://www.youtube.com/watch?v=a b")
        XCTAssertNotNil(u)
        XCTAssertTrue(u!.absoluteString.hasPrefix("https://www.youtube.com/oembed?"))
        XCTAssertTrue(u!.absoluteString.contains("format=json"))
    }
}
