#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The artwork grid's source chips decide what is drawn *and* what SELECT ALL,
/// the counter and STAGE act on. They used to decide only the first, which is
/// how filtering to the Cover Art Archive and pressing SELECT ALL staged the
/// hidden Discogs scans too.
final class ArtworkSelectionScopeTests: XCTestCase {

    private func image(_ name: String, _ source: RemoteArtworkSource) -> RemoteArtworkImage {
        RemoteArtworkImage(
            imageURL: URL(string: "https://example.test/\(source.rawValue)/\(name).jpg")!,
            thumbnailURL: URL(string: "https://example.test/\(source.rawValue)/\(name)-150.jpg")!,
            types: [],
            comment: "",
            front: false,
            back: false,
            source: source
        )
    }

    /// Two scans of one pressing from each database, plus a file off the disk,
    /// which is the shape the grid actually holds.
    private lazy var grid: [RemoteArtworkImage] = [
        image("front", .coverArtArchive),
        image("booklet", .coverArtArchive),
        image("primary", .discogs),
        image("secondary", .discogs),
        image("scan", .localFile),
    ]

    private var everything: Set<String> { Set(grid.map(\.id)) }

    // MARK: - Visibility

    func testNoFilterShowsEverythingInGridOrder() {
        let visible = ArtworkSelectionScope.visible(grid, source: nil)
        XCTAssertEqual(visible.map(\.id), grid.map(\.id))
    }

    func testAFilterShowsOnlyThatSource() {
        XCTAssertEqual(
            ArtworkSelectionScope.visible(grid, source: .coverArtArchive).map(\.source),
            [.coverArtArchive, .coverArtArchive]
        )
        XCTAssertEqual(ArtworkSelectionScope.visible(grid, source: .localFile).count, 1)
    }

    // MARK: - What an action applies to

    /// The bug, in one assertion: everything is selected, the archive chip is
    /// on, and staging must fetch the two archive scans and nothing else.
    func testFilteredStagingLeavesHiddenSourcesAlone() {
        let staged = ArtworkSelectionScope.actionable(grid, selected: everything, source: .coverArtArchive)

        XCTAssertEqual(staged.map(\.id), [grid[0].id, grid[1].id])
        XCTAssertFalse(staged.contains { $0.source == .discogs },
                       "a hidden Discogs scan must never be staged by a filtered SELECT ALL")
        XCTAssertFalse(staged.contains { $0.source == .localFile })
    }

    /// Hiding is not deselecting. The selection survives the filter, so lifting
    /// the chip shows those tiles still ticked rather than silently emptied.
    func testHiddenImagesKeepTheirSelection() {
        let unfiltered = ArtworkSelectionScope.actionable(grid, selected: everything, source: nil)
        XCTAssertEqual(unfiltered.count, grid.count)
    }

    func testUnselectedVisibleImagesAreNotActedOn() {
        let onlyBooklet: Set<String> = [grid[1].id]
        let staged = ArtworkSelectionScope.actionable(grid, selected: onlyBooklet, source: .coverArtArchive)
        XCTAssertEqual(staged.map(\.id), [grid[1].id])
    }

    func testGridOrderIsPreservedRatherThanSelectionOrder() {
        // A set has no order, so the grid's own order is the only stable one:
        // it is what the filename numbering (booklet_01, booklet_02) counts.
        let staged = ArtworkSelectionScope.actionable(grid, selected: everything, source: nil)
        XCTAssertEqual(staged.map(\.id), grid.map(\.id))
    }

    func testEmptySelectionActsOnNothing() {
        XCTAssertTrue(ArtworkSelectionScope.actionable(grid, selected: [], source: nil).isEmpty)
        XCTAssertTrue(ArtworkSelectionScope.actionable(grid, selected: [], source: .discogs).isEmpty)
    }

    /// A stale id, from an image the grid dropped when the release changed,
    /// selects nothing rather than crashing a lookup.
    func testUnknownSelectedIDsAreIgnored() {
        let staged = ArtworkSelectionScope.actionable(grid, selected: ["https://gone.test/x.jpg"], source: nil)
        XCTAssertTrue(staged.isEmpty)
    }

    func testFilteringToASourceWithNothingInItActsOnNothing() {
        let archiveOnly = [image("front", .coverArtArchive)]
        let staged = ArtworkSelectionScope.actionable(
            archiveOnly, selected: Set(archiveOnly.map(\.id)), source: .discogs
        )
        XCTAssertTrue(staged.isEmpty)
    }
}
#endif
