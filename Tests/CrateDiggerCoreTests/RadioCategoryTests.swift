import XCTest
@testable import CrateDiggerCore

final class RadioCategoryTests: XCTestCase {
    private func make(_ id: String, kind: StreamKind) -> StreamSource {
        StreamSource(id: id, url: "https://youtube.com/watch?v=\(id)", title: id,
                     channel: "ch", kind: kind, hue: 1, addedAt: Date())
    }

    func testLiveStreamsAreYTLive() {
        XCTAssertEqual(RadioCategory.of(make("a", kind: .live)), .youtubeLive)
    }

    func testNonLiveStreamsAreYTRecords() {
        for kind: StreamKind in [.video, .mix, .playlist] {
            XCTAssertEqual(RadioCategory.of(make("x", kind: kind)), .youtubeRecords,
                           "\(kind) should be a record")
        }
    }

    func testContainsMatchesOf() {
        let live = make("l", kind: .live)
        let vod = make("v", kind: .mix)
        XCTAssertTrue(RadioCategory.youtubeLive.contains(live))
        XCTAssertFalse(RadioCategory.youtubeLive.contains(vod))
        XCTAssertTrue(RadioCategory.youtubeRecords.contains(vod))
        XCTAssertFalse(RadioCategory.youtubeRecords.contains(live))
    }

    func testTitles() {
        XCTAssertEqual(RadioCategory.youtubeLive.title, "YT Live")
        XCTAssertEqual(RadioCategory.youtubeRecords.title, "YT Records")
    }
}
