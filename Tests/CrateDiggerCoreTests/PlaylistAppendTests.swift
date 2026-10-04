#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Adding to a playlist from a menu or a drag must never duplicate an entry or
/// write something an M3U cannot hold.
final class PlaylistAppendTests: XCTestCase {
    private func urls(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/Music/\($0).mp3") }
    }
    private func names(_ urls: [URL]) -> [String] {
        urls.map { $0.deletingPathExtension().lastPathComponent }
    }

    func testAppendsNewEntriesAtTheEndInTheGivenOrder() {
        let result = Playlist.appending(urls("c", "d"), to: urls("a", "b"))
        XCTAssertEqual(names(result), ["a", "b", "c", "d"])
    }

    func testSkipsEntriesAlreadyInThePlaylist() {
        let result = Playlist.appending(urls("b", "c"), to: urls("a", "b"))
        XCTAssertEqual(names(result), ["a", "b", "c"])
    }

    /// An artist and one of its albums both selected resolve to the same
    /// file twice; it lands once.
    func testSkipsDuplicatesWithinTheBatch() {
        let result = Playlist.appending(urls("c", "c", "d", "c"), to: urls("a"))
        XCTAssertEqual(names(result), ["a", "c", "d"])
    }

    func testMatchesStandardizedPaths() {
        let existing = [URL(fileURLWithPath: "/Music/x/../a.mp3")]
        let result = Playlist.appending(urls("a"), to: existing)
        XCTAssertEqual(result.count, 1)
    }

    /// A Subsonic stream has no path an M3U on this Mac could play.
    func testDropsNonFileURLs() {
        let stream = URL(string: "https://music.example.com/rest/stream?id=1")!
        let result = Playlist.appending([stream] + urls("c"), to: urls("a"))
        XCTAssertEqual(names(result), ["a", "c"])
    }

    func testNothingNewLeavesThePlaylistUnchanged() {
        let list = urls("a", "b")
        XCTAssertEqual(Playlist.appending(urls("a", "b"), to: list), list)
    }
}
#endif
