#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// A view is one to three facets, left to right. Three rules and nothing
/// else: not empty, not wider than three, no facet twice, Track only last.
final class BrowserViewTests: XCTestCase {

    func testTheClassicAndTableViewsAreValid() {
        XCTAssertNil(BrowserView.classic.problem)
        XCTAssertEqual(BrowserView.classic.facets, [.artist, .album, .track])
        XCTAssertNil(BrowserView.table.problem)
        XCTAssertEqual(BrowserView.table.facets, [.track])
    }

    func testEmptyIsAProblem() {
        XCTAssertEqual(BrowserView([]).problem, .empty)
    }

    func testFourColumnsIsAProblem() {
        XCTAssertEqual(BrowserView([.genre, .artist, .album, .track]).problem, .tooWide)
    }

    func testARepeatedFacetIsAProblem() {
        XCTAssertEqual(BrowserView([.artist, .artist, .track]).problem, .duplicate(.artist))
    }

    /// Nothing cascades out of a track.
    func testTrackAnywhereButLastIsAProblem() {
        XCTAssertEqual(BrowserView([.track, .album]).problem, .trackNotLast)
        XCTAssertNil(BrowserView([.genre, .track]).problem)
    }

    /// A view can end on an album or an artist: the leaf need not be tracks.
    func testAViewWithoutTracksIsValid() {
        XCTAssertNil(BrowserView([.genre, .artist, .album]).problem)
        XCTAssertNil(BrowserView([.artist]).problem)
    }

    // MARK: - Legacy layouts

    func testEveryLegacyLayoutMapsToAView() {
        XCTAssertEqual(BrowserView(legacy: .full).facets, [.artist, .album, .track])
        XCTAssertEqual(BrowserView(legacy: .albumTrack).facets, [.album, .track])
        XCTAssertEqual(BrowserView(legacy: .track).facets, [.track])
    }

    // MARK: - Growing and shrinking

    /// Adding inserts the first facet the view lacks, in a fixed preference
    /// order, with Track always landing last.
    func testAddingAppendsTrackFirst() {
        XCTAssertEqual(BrowserView([.artist]).adding().facets, [.artist, .track])
    }

    func testAddingGoesBeforeATrailingTrackColumn() {
        XCTAssertEqual(BrowserView([.artist, .track]).adding().facets, [.artist, .album, .track])
        XCTAssertEqual(BrowserView([.genre, .track]).adding().facets, [.genre, .album, .track])
    }

    func testAddingSkipsFacetsAlreadyPresent() {
        XCTAssertEqual(BrowserView([.album, .track]).adding().facets, [.album, .artist, .track])
    }

    func testAddingToAFullViewIsANoOp() {
        let full = BrowserView([.genre, .artist, .track])
        XCTAssertEqual(full.adding(), full)
    }

    func testDroppingLastRemovesTheLastColumn() {
        XCTAssertEqual(BrowserView.classic.droppingLast().facets, [.artist, .album])
    }

    func testDroppingTheOnlyColumnIsANoOp() {
        XCTAssertEqual(BrowserView.table.droppingLast(), .table)
    }

    // MARK: - Swapping a column

    func testReplacingAColumnKeepsTheOthers() {
        let swapped = BrowserView.classic.replacing(column: 0, with: .genre)
        XCTAssertEqual(swapped.facets, [.genre, .album, .track])
    }

    /// The header menu greys out choices that would break a rule.
    func testCanReplaceRefusesADuplicateAndAMisplacedTrack() {
        let classic = BrowserView.classic
        XCTAssertFalse(classic.canReplace(column: 0, with: .album), "album is already column 1")
        XCTAssertFalse(classic.canReplace(column: 0, with: .track), "track only last")
        XCTAssertTrue(classic.canReplace(column: 0, with: .genre))
        XCTAssertTrue(classic.canReplace(column: 2, with: .album) == false, "album already present")
        XCTAssertTrue(BrowserView([.artist, .album]).canReplace(column: 1, with: .track))
    }

    func testColumnOfFacet() {
        XCTAssertEqual(BrowserView.classic.column(of: .album), 1)
        XCTAssertNil(BrowserView.classic.column(of: .genre))
    }

    func testViewsRoundTripThroughJSON() throws {
        let view = BrowserView([.decade, .albumArtist, .track])
        let data = try JSONEncoder().encode(view)
        XCTAssertEqual(try JSONDecoder().decode(BrowserView.self, from: data), view)
    }
}
#endif
