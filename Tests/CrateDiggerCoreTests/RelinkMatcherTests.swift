#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class RelinkMatcherTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testMatchesByFilename() {
        let map = RelinkMatcher.match(
            missing: [url("/old/Album/01.flac")],
            candidates: [url("/new/Album/01.flac"), url("/new/Album/02.flac")]
        )
        XCTAssertEqual(map[url("/old/Album/01.flac")], url("/new/Album/01.flac"))
    }

    func testUnmatchedFileIsOmitted() {
        let map = RelinkMatcher.match(
            missing: [url("/old/gone.flac")],
            candidates: [url("/new/other.flac")]
        )
        XCTAssertTrue(map.isEmpty)
    }

    func testCaseInsensitiveFilename() {
        let map = RelinkMatcher.match(
            missing: [url("/old/Song.FLAC")],
            candidates: [url("/new/song.flac")]
        )
        XCTAssertEqual(map[url("/old/Song.FLAC")], url("/new/song.flac"))
    }

    func testAmbiguousNamePrefersLongestSharedTrailingPath() {
        let map = RelinkMatcher.match(
            missing: [url("/old/Rock/Album/01.flac")],
            candidates: [url("/new/Jazz/Album/01.flac"), url("/new/Rock/Album/01.flac")]
        )
        XCTAssertEqual(map[url("/old/Rock/Album/01.flac")], url("/new/Rock/Album/01.flac"))
    }

    func testDuplicateFilenamesClaimDistinctCandidates() {
        let missing = [url("/old/A/01.flac"), url("/old/B/01.flac")]
        let map = RelinkMatcher.match(
            missing: missing,
            candidates: [url("/new/A/01.flac"), url("/new/B/01.flac")]
        )
        XCTAssertEqual(map[url("/old/A/01.flac")], url("/new/A/01.flac"))
        XCTAssertEqual(map[url("/old/B/01.flac")], url("/new/B/01.flac"))
        XCTAssertEqual(Set(map.values).count, 2, "each candidate used at most once")
    }
}
#endif
