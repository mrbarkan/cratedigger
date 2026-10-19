#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class ArtworkReleaseListTests: XCTestCase {

    private func release(_ id: String,
                         title: String = "OK Computer",
                         date: String? = nil,
                         country: String? = nil,
                         formats: [String] = [],
                         status: String? = "Official",
                         disambiguation: String? = nil,
                         group: String? = "rg") -> MBReleaseCandidate {
        MBReleaseCandidate(id: id, title: title, date: date, country: country, barcode: nil,
                           format: formats.first, status: status, disambiguation: disambiguation,
                           trackCount: nil, releaseGroupID: group, formats: formats)
    }

    // MARK: - Media summary

    func testMediaSummaryCountsRepeatedFormats() {
        XCTAssertEqual(release("a", formats: ["CD"]).mediaSummary, "CD")
        XCTAssertEqual(release("a", formats: ["CD", "CD"]).mediaSummary, "2×CD")
        XCTAssertEqual(release("a", formats: ["CD", "DVD"]).mediaSummary, "CD + DVD")
        XCTAssertEqual(release("a", formats: ["CD", "CD", "DVD-Video"]).mediaSummary, "2×CD + DVD-Video")
        XCTAssertNil(release("a").mediaSummary)
    }

    func testTheOldSingleFormatInitialiserStillFillsFormats() {
        let old = MBReleaseCandidate(id: "x", title: "t", date: nil, country: nil, barcode: nil,
                                     format: "Cassette", status: nil, disambiguation: nil, trackCount: nil)
        XCTAssertEqual(old.formats, ["Cassette"])
    }

    // MARK: - Filters

    /// The MEDIA menu lists every medium a result carries, so its filter has
    /// to match on any medium: a CD + DVD set filed only under "CD" vanished
    /// when the user picked DVD from the menu it was listed in.
    func testAMediaFilterMatchesAnyMedium() {
        let releases = [release("cd", formats: ["CD"]),
                        release("combo", formats: ["CD", "DVD"]),
                        release("lp", formats: ["12\" Vinyl"])]
        XCTAssertEqual(ArtworkReleaseList.formats(in: releases), ["12\" Vinyl", "CD", "DVD"])
        XCTAssertEqual(ArtworkReleaseList.displayed(releases, media: "DVD", country: nil, sort: .relevance).map(\.id),
                       ["combo"])
        XCTAssertEqual(ArtworkReleaseList.displayed(releases, media: "CD", country: nil, sort: .relevance).map(\.id),
                       ["cd", "combo"])
    }

    func testCountryFilterAndMenu() {
        let releases = [release("gb", country: "GB"), release("us", country: "US"), release("none")]
        XCTAssertEqual(ArtworkReleaseList.countries(in: releases), ["GB", "US"])
        XCTAssertEqual(ArtworkReleaseList.displayed(releases, media: nil, country: "US", sort: .relevance).map(\.id),
                       ["us"])
    }

    // MARK: - Sorting

    func testYearSortPutsUndatedLastAndKeepsTiesInOrder() {
        let releases = [release("none"), release("b97", date: "1997-06-16"), release("2009", date: "2009"),
                        release("a97", date: "1997-05-21")]
        XCTAssertEqual(ArtworkReleaseList.displayed(releases, media: nil, country: nil, sort: .year).map(\.id),
                       ["b97", "a97", "2009", "none"])
    }

    /// BEST ART: a measured front beats an unmeasured one, a known front
    /// beats none, and the image count breaks what's left. Rows that tie
    /// keep MusicBrainz's order, so the list doesn't shuffle as counts land.
    func testArtSortPrefersMeasuredFrontsThenFrontsThenCounts() {
        let releases = ["plain", "many", "front", "big", "small", "tie"].map { release($0) }
        let counts: [String: CoverArtCount] = [
            "plain": .known(CoverArtSummary(count: 0, hasFront: false, hasBack: false)),
            "many": .known(CoverArtSummary(count: 20, hasFront: false, hasBack: true)),
            "front": .known(CoverArtSummary(count: 1, hasFront: true, hasBack: false)),
            "big": .known(CoverArtSummary(count: 1, hasFront: true, hasBack: false)),
            "small": .known(CoverArtSummary(count: 9, hasFront: true, hasBack: false)),
            "tie": .pending
        ]
        let sizes = ["big": ArtworkDimensions(width: 3000, height: 3000),
                     "small": ArtworkDimensions(width: 500, height: 500)]
        let order = ArtworkReleaseList.displayed(releases, media: nil, country: nil, sort: .art,
                                                 counts: counts, frontSizes: sizes).map(\.id)
        XCTAssertEqual(order, ["big", "small", "front", "many", "plain", "tie"])
    }

    func testRelevanceKeepsMusicBrainzOrder() {
        let releases = ["c", "a", "b"].map { release($0) }
        XCTAssertEqual(ArtworkReleaseList.displayed(releases, media: nil, country: nil, sort: .relevance).map(\.id),
                       ["c", "a", "b"])
    }

    // MARK: - Grouping

    func testGroupsPutStandardFirstAndCountWhatTheyHold() {
        let releases = [release("deluxe", title: "OK Computer (Deluxe)"),
                        release("std1"),
                        release("remaster", disambiguation: "2017 remaster"),
                        release("std2")]
        let groups = ArtworkReleaseList.grouped(releases)
        XCTAssertEqual(groups.map(\.edition), ["Standard", "Deluxe", "Remastered"])
        XCTAssertEqual(groups[0].releases.map(\.id), ["std1", "std2"])
        XCTAssertEqual(groups.map(\.releases.count).reduce(0, +), releases.count,
                       "every displayed release is in exactly one group")
    }

    func testEditionReadsSuperDeluxeAsDeluxe() {
        XCTAssertEqual(ArtworkReleaseList.edition(of: release("x", title: "Kid A (Super Deluxe)")), "Deluxe")
        XCTAssertEqual(ArtworkReleaseList.edition(of: release("x", title: "Kid A")), "Standard")
    }

    // MARK: - Best match

    func testBestMatchFavoursTitleStatusMediumAndYear() {
        let releases = [release("bootleg", status: "Bootleg"),
                        release("lp", date: "1997", formats: ["12\" Vinyl"]),
                        release("cd97", date: "1997-06-16", formats: ["CD"]),
                        release("other", title: "Airbag")]
        XCTAssertEqual(ArtworkReleaseList.bestMatchID(in: releases, albumTitle: "OK Computer",
                                                      albumYear: 1997, albumMedia: .cd), "cd97")
        XCTAssertEqual(ArtworkReleaseList.bestMatchID(in: releases, albumTitle: "OK Computer",
                                                      albumYear: 1997, albumMedia: .vinyl), "lp")
    }

    func testNoBestMatchWithoutATitleMatch() {
        XCTAssertNil(ArtworkReleaseList.bestMatchID(in: [release("x", title: "Pablo Honey")],
                                                    albumTitle: "OK Computer", albumYear: nil, albumMedia: nil))
    }

    // MARK: - Count states

    func testALookupThatCameBackEmptyHandedIsUnknownNotZero() {
        XCTAssertEqual(CoverArtCount(lookup: nil), .unknown)
        let summary = CoverArtSummary(count: 0, hasFront: false, hasBack: false)
        XCTAssertEqual(CoverArtCount(lookup: summary), .known(summary))
        XCTAssertNil(CoverArtCount.pending.summary)
    }

    func testCountBatchesFollowTheListOrderOneRequestPerGroup() {
        let releases = [release("a1", group: "A"), release("b1", group: "B"), release("loose", group: nil),
                        release("a2", group: "A"), release("a1", group: "A")]
        XCTAssertEqual(CoverArtCountPlan.batches(for: releases), [
            .releaseGroup(id: "A", releaseIDs: ["a1", "a2"]),
            .releaseGroup(id: "B", releaseIDs: ["b1"]),
            .release(id: "loose")
        ])
    }

    // MARK: - HD

    func testHDMeansTheShortSide() {
        XCTAssertTrue(ArtworkDimensions(width: 1200, height: 1200).isHighResolution)
        XCTAssertFalse(ArtworkDimensions(width: 1400, height: 700).isHighResolution)
        XCTAssertFalse(ArtworkDimensions(width: 600, height: 600).isHighResolution)
    }
}

final class ArtworkGridStatusTests: XCTestCase {

    func testImagesOnScreenAlwaysShowTheGrid() {
        XCTAssertEqual(ArtworkGridStatus.resolve(imageCount: 3, archive: .loading, discogs: .loading), .grid)
        XCTAssertEqual(ArtworkGridStatus.resolve(imageCount: 1, archive: .failed("x"), discogs: .loaded(count: 1)), .grid)
    }

    /// The lie this replaces: the archive came back empty, Discogs was still
    /// looking, and the grid already said "No scans".
    func testNeverClaimsNoScansWhileASourceIsStillLooking() {
        guard case .loading = ArtworkGridStatus.resolve(imageCount: 0, archive: .loaded(count: 0), discogs: .loading)
        else { return XCTFail("said there were no scans while Discogs was still looking") }
        guard case .loading = ArtworkGridStatus.resolve(imageCount: 0, archive: .loading, discogs: .loaded(count: 0))
        else { return XCTFail("said there were no scans while the archive was still answering") }
    }

    /// The other lie: an archive error used to skip Discogs entirely and stand
    /// as the whole answer.
    func testAnArchiveFailureStillWaitsForDiscogs() {
        guard case let .loading(detail) = ArtworkGridStatus.resolve(imageCount: 0, archive: .failed("Archive down."),
                                                                     discogs: .loading)
        else { return XCTFail() }
        XCTAssertTrue(detail.contains("Discogs"))
    }

    func testFailuresAreFailuresAndEmptiesAreEmpty() {
        XCTAssertEqual(ArtworkGridStatus.resolve(imageCount: 0, archive: .failed("Archive down."), discogs: .idle),
                       .failed(detail: "Archive down."))
        guard case .failed = ArtworkGridStatus.resolve(imageCount: 0, archive: .failed("Archive down."),
                                                        discogs: .loaded(count: 0))
        else { return XCTFail("an archive error with an empty Discogs is still a failure, not 'no scans'") }
        guard case .empty = ArtworkGridStatus.resolve(imageCount: 0, archive: .loaded(count: 0), discogs: .idle)
        else { return XCTFail() }
        guard case let .empty(detail) = ArtworkGridStatus.resolve(imageCount: 0, archive: .loaded(count: 0),
                                                                   discogs: .loaded(count: 0))
        else { return XCTFail() }
        XCTAssertTrue(detail.contains("Neither"))
    }

    func testCopyHasNoDashes() {
        let states: [(ArtworkSourceLoad, ArtworkSourceLoad)] = [
            (.loading, .loading), (.loading, .idle), (.failed("x."), .loading), (.loaded(count: 0), .loading),
            (.failed("x."), .failed("y.")), (.loaded(count: 0), .failed("y.")), (.loaded(count: 0), .loaded(count: 0)),
            (.loaded(count: 0), .idle)
        ]
        for (archive, discogs) in states {
            let text: String
            switch ArtworkGridStatus.resolve(imageCount: 0, archive: archive, discogs: discogs) {
            case .grid: text = ""
            case let .loading(detail), let .empty(detail), let .failed(detail): text = detail
            }
            XCTAssertFalse(text.contains("—") || text.contains("–"), text)
        }
    }
}
#endif
