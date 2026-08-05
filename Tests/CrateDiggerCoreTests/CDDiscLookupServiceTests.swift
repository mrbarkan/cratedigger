#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Parsing is checked against a real MusicBrainz response for a real disc, not a
/// hand-written sample — the shapes that break decoders (multi-disc box sets,
/// per-track artist credits, missing dates) only show up in the genuine article.
final class CDDiscLookupServiceTests: XCTestCase {

    private let atomHeartMother = CompactDiscTOC(
        firstTrack: 1, lastTrack: 5, leadoutBlock: 234673,
        trackOffsets: [150, 106826, 127134, 151806, 176087]
    )

    // MARK: - Request building

    func testLookupURLAsksForRecordingsAndArtists() throws {
        let url = try XCTUnwrap(MusicBrainzDiscClient.lookupURL(discID: atomHeartMother.musicBrainzDiscID))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "musicbrainz.org")
        XCTAssertTrue(components.path.hasSuffix("/discid/DCzNRTeswcuOG8kdU4Zv5XaFlhQ-"))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first { $0.name == "fmt" }?.value, "json")
        // Without recordings the response names the release but none of its
        // tracks — which is most of what a rip needs.
        XCTAssertEqual(items.first { $0.name == "inc" }?.value, "recordings+artist-credits")
    }

    func testLookupURLIsNilWithoutADiscID() {
        XCTAssertNil(MusicBrainzDiscClient.lookupURL(discID: ""))
    }

    /// A disc MusicBrainz doesn't know should still leave the user somewhere to go.
    func testSubmissionURLCarriesTheFullTOC() throws {
        let url = try XCTUnwrap(MusicBrainzDiscClient.submissionURL(for: atomHeartMother))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "id" }?.value, "DCzNRTeswcuOG8kdU4Zv5XaFlhQ-")
        XCTAssertEqual(items.first { $0.name == "tracks" }?.value, "5")
        XCTAssertEqual(items.first { $0.name == "toc" }?.value,
                       "1+5+234673+150+106826+127134+151806+176087")
    }

    // MARK: - Parsing a real response

    func testParsesRealDiscIDResponse() throws {
        let candidates = MusicBrainzDiscClient.parse(try fixture("AtomHeartMother.discid.json"))
        XCTAssertEqual(candidates.count, 9, "this TOC genuinely matches nine pressings")

        let standalone = try XCTUnwrap(candidates.first { $0.totalDiscs == 1 })
        XCTAssertEqual(standalone.title, "Atom Heart Mother")
        XCTAssertEqual(standalone.artist, "Pink Floyd")
        XCTAssertEqual(standalone.year, 2011)
        XCTAssertEqual(standalone.source, .musicBrainz)
        XCTAssertEqual(standalone.tracks.count, 5)
        XCTAssertEqual(standalone.tracks.first?.position, 1)
        XCTAssertTrue(standalone.tracks[1].title == "If", "track 2 of this pressing is “If”")
        XCTAssertEqual(standalone.tracks.last?.title.hasPrefix("Alan’s Psychedelic Breakfast"), true)
    }

    /// The same disc appears inside box sets; those must survive parsing too,
    /// because choosing between them is the user's call.
    func testBoxSetReleasesKeepEveryDisc() throws {
        let candidates = MusicBrainzDiscClient.parse(try fixture("AtomHeartMother.discid.json"))
        let boxSet = try XCTUnwrap(candidates.first { ($0.totalDiscs ?? 1) > 1 })
        XCTAssertGreaterThan(boxSet.tracks.count, 5)
        XCTAssertGreaterThan(Set(boxSet.tracks.map(\.discNumber)).count, 1,
                             "tracks should carry the disc they came from")
    }

    func testTrackDurationsConvertFromMilliseconds() throws {
        let candidates = MusicBrainzDiscClient.parse(try fixture("AtomHeartMother.discid.json"))
        let standalone = try XCTUnwrap(candidates.first { $0.totalDiscs == 1 })
        // The title suite runs ~23:44; MusicBrainz reports milliseconds.
        let suite = try XCTUnwrap(standalone.tracks.first?.durationSeconds)
        XCTAssertEqual(suite, 1422, accuracy: 5)
    }

    func testEveryCandidateGetsACoverArtArchiveURL() throws {
        for candidate in MusicBrainzDiscClient.parse(try fixture("AtomHeartMother.discid.json")) {
            let url = try XCTUnwrap(candidate.artworkURL)
            XCTAssertTrue(url.absoluteString.hasPrefix("https://coverartarchive.org/release/"))
            XCTAssertTrue(url.absoluteString.hasSuffix("/front"))
        }
    }

    func testParsingGarbageYieldsNoCandidates() {
        for payload in ["", "{}", #"{"releases": []}"#, "not json", #"{"releases":[{"title":"no id"}]}"#] {
            XCTAssertTrue(MusicBrainzDiscClient.parse(Data(payload.utf8)).isEmpty,
                          "should not invent a candidate from: \(payload)")
        }
    }

    func testUnknownDiscIsADistinctOutcome() {
        // 404 is the normal answer for a well-formed but unindexed disc, and the
        // UI needs to tell that apart from a network failure.
        XCTAssertEqual(CDDiscLookupError.discNotFound, CDDiscLookupError.discNotFound)
        XCTAssertNotEqual(CDDiscLookupError.discNotFound, CDDiscLookupError.badStatus(404))
        XCTAssertNotNil(CDDiscLookupError.discNotFound.errorDescription)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }
}
#endif
