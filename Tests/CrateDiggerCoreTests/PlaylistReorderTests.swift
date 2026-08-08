#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// A playlist's order is its content — a reorder that drops or duplicates an
/// entry silently corrupts the thing the user made.
final class PlaylistReorderTests: XCTestCase {
    private func urls(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/Music/\($0).mp3") }
    }
    private func names(_ urls: [URL]) -> [String] {
        urls.map { $0.deletingPathExtension().lastPathComponent }
    }

    func testMovesOneEntryBeforeAnother() {
        let list = urls("a", "b", "c", "d")
        let result = Playlist.reordered(list, moving: urls("d"), before: urls("b").first)
        XCTAssertEqual(names(result), ["a", "d", "b", "c"])
    }

    func testMovingEarlierEntryLater() {
        let list = urls("a", "b", "c", "d")
        let result = Playlist.reordered(list, moving: urls("a"), before: urls("d").first)
        XCTAssertEqual(names(result), ["b", "c", "a", "d"])
    }

    /// A multi-selection lands in list order, not click order.
    func testMovedRunKeepsTheListsOwnOrder() {
        let list = urls("a", "b", "c", "d", "e")
        let result = Playlist.reordered(list, moving: urls("d", "b"), before: urls("a").first)
        XCTAssertEqual(names(result), ["b", "d", "a", "c", "e"])
    }

    func testNilDestinationAppends() {
        let list = urls("a", "b", "c")
        let result = Playlist.reordered(list, moving: urls("a"), before: nil)
        XCTAssertEqual(names(result), ["b", "c", "a"])
    }

    /// Dropping a selection onto one of its own rows would otherwise try to
    /// insert before an entry that no longer exists in the reduced list.
    func testDroppingOntoItselfAppendsRatherThanLosingRows() {
        let list = urls("a", "b", "c")
        let result = Playlist.reordered(list, moving: urls("a", "b"), before: urls("b").first)
        XCTAssertEqual(names(result), ["c", "a", "b"])
    }

    func testNeverDropsOrDuplicatesEntries() {
        let list = urls("a", "b", "c", "d", "e")
        for moving in [urls("a"), urls("c", "e"), urls("a", "b", "c", "d", "e")] {
            for destination in [urls("a").first, urls("c").first, urls("e").first, nil] {
                let result = Playlist.reordered(list, moving: moving, before: destination)
                XCTAssertEqual(Set(names(result)), Set(names(list)))
                XCTAssertEqual(result.count, list.count, "moving \(names(moving)) → \(destination?.lastPathComponent ?? "end")")
            }
        }
    }

    /// The same file reached by a different path spelling is the same entry.
    func testMatchesEntriesByStandardizedPath() {
        let list = urls("a", "b", "c")
        let awkward = URL(fileURLWithPath: "/Music/../Music/a.mp3")
        let result = Playlist.reordered(list, moving: [awkward], before: urls("c").first)
        XCTAssertEqual(names(result), ["b", "a", "c"])
    }

    func testEmptyMoveIsANoOp() {
        let list = urls("a", "b")
        XCTAssertEqual(names(Playlist.reordered(list, moving: [], before: urls("a").first)), ["a", "b"])
    }
}
#endif
