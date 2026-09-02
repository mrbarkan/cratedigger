#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The gallery's dividers: cut from the sorted list wherever the label the
/// sort compares on changes, and the arrow keys' row arithmetic across them.
final class GallerySectionTests: XCTestCase {
    private func album(_ id: String, title: String, artist: String = "Air", year: Int? = nil, original: Int? = nil) -> Album {
        Album(id: id, artistID: artist, artistName: artist, title: title, year: year,
              artworkHash: nil, tracks: [], originalYear: original)
    }

    func testYearDividersFollowTheSortAndPutUnknownLast() {
        let albums = LibraryIndex.sortedAlbums([
            album("a", title: "A", year: 2001), album("b", title: "B", year: nil),
            album("c", title: "C", year: 1998), album("d", title: "D", year: 2001, original: 1972),
        ], by: .year)
        let sections = GallerySection.sections(of: albums, by: .year)
        XCTAssertEqual(sections.map(\.title), ["1972", "1998", "2001", "Unknown Year"])
        XCTAssertEqual(sections.map { $0.albums.map(\.id) }, [["d"], ["c"], ["a"], ["b"]])
    }

    func testDescendingKeepsTheSortedOrder() {
        let albums = LibraryIndex.sortedAlbums([
            album("a", title: "A", year: 2001), album("c", title: "C", year: 1998),
        ], by: .year, ascending: false)
        XCTAssertEqual(GallerySection.sections(of: albums, by: .year).map(\.title), ["2001", "1998"])
    }

    func testInitialsFoldAccentsAndBucketNonLetters() {
        XCTAssertEqual(GallerySection.title(for: album("1", title: "72 Seasons"), by: .title), "#")
        XCTAssertEqual(GallerySection.title(for: album("2", title: "Élan"), by: .title), "E")
        XCTAssertEqual(GallerySection.title(for: album("3", title: "the national"), by: .title), "T")
        XCTAssertEqual(GallerySection.title(for: album("4", title: "  "), by: .title), "#")
        XCTAssertEqual(GallerySection.title(for: album("5", title: "X", artist: " "), by: .albumArtist), "Unknown Artist")
    }

    func testEveryDividerHasItsOwnID() {
        let albums = [album("a", title: "Alpha"), album("b", title: "Beta"), album("c", title: "Avalon")]
        // Not re-sorted: a run split by another run keeps two "A" dividers apart.
        let ids = GallerySection.sections(of: albums, by: .title).map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
    }

    // MARK: - Arrow keys

    /// Five covers over four, three to a row:
    ///   0 1 2        5 6 7
    ///   3 4          8
    private var twoSections: [GallerySection] {
        GallerySection.sections(of: [
            album("0", title: "A0"), album("1", title: "A1"), album("2", title: "A2"), album("3", title: "A3"), album("4", title: "A4"),
            album("5", title: "B0"), album("6", title: "B1"), album("7", title: "B2"), album("8", title: "B3"),
        ], by: .title)
    }

    func testDownStaysInTheColumnAndCrossesTheDivider() {
        let s = twoSections
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 1, in: s, columns: 3, down: true), 4)
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 2, in: s, columns: 3, down: true), 4, "short row: clamps to its last cover")
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 4, in: s, columns: 3, down: true), 6, "into the next section, same column")
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 7, in: s, columns: 3, down: true), 8)
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 8, in: s, columns: 3, down: true), 8, "nothing below")
    }

    func testUpStaysInTheColumnAndCrossesTheDivider() {
        let s = twoSections
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 4, in: s, columns: 3, down: false), 1)
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 5, in: s, columns: 3, down: false), 3, "into the previous section's last row")
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 7, in: s, columns: 3, down: false), 4, "last row is short: its last cover")
        XCTAssertEqual(GallerySection.verticalNeighbor(of: 0, in: s, columns: 3, down: false), 0, "nothing above")
    }
}
#endif
