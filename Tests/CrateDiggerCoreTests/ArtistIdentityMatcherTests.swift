import XCTest
@testable import CrateDiggerCore

/// Who an artist is on MusicBrainz: the picture finder's match rule (a
/// fold-equal name plus one telling album title in common), applied to
/// MusicBrainz artists and their release groups.
final class ArtistIdentityMatcherTests: XCTestCase {
    private func candidate(_ id: String, _ name: String, _ titles: [String])
        -> (ArtistIdentityCandidate, releaseGroupTitles: [String]) {
        (ArtistIdentityCandidate(musicBrainzID: id, name: name), releaseGroupTitles: titles)
    }

    func testOneConfidentIsConfirmed() {
        let identity = ArtistIdentityMatcher.decide(
            name: "Massive Attack", libraryAlbumTitles: ["Mezzanine (Deluxe Edition)"],
            candidates: [candidate("ma", "Massive Attack", ["Blue Lines", "Mezzanine"]),
                         candidate("other", "Massive Attack", ["Something Else"]),
                         candidate("tribute", "Massive Attack Tribute", ["Mezzanine"])],
            rejected: [])
        XCTAssertEqual(identity, .confirmed(musicBrainzID: "ma", wikidataID: nil))
    }

    /// Review focus 1: two acts called Boston, and nothing but the
    /// self-titled album and a generic title to tell them apart.
    func testTwoSameNamedArtistsStayUncertain() {
        let identity = ArtistIdentityMatcher.decide(
            name: "Boston", libraryAlbumTitles: ["Boston", "Greatest Hits"],
            candidates: [candidate("b1", "Boston", ["Boston", "Don't Look Back", "Greatest Hits"]),
                         candidate("b2", "Boston", ["Boston", "Greatest Hits"]),
                         candidate("x", "Bastion", ["Boston"])],
            rejected: [])
        guard case .uncertain(let held) = identity else { return XCTFail("\(identity)") }
        XCTAssertEqual(held.map(\.musicBrainzID), ["b1", "b2"])
        XCTAssertEqual(held.first?.releaseTitles, ["Boston", "Don't Look Back", "Greatest Hits"])

        // Two that both share a telling album are an ambiguity too, never a pick.
        let both = ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [candidate("a1", "Air", ["Moon Safari"]), candidate("a2", "AIR", ["Moon Safari"])],
            rejected: [])
        guard case .uncertain(let pair) = both else { return XCTFail("\(both)") }
        XCTAssertEqual(pair.map(\.musicBrainzID), ["a1", "a2"])
    }

    func testSelfTitledAloneIsNotEnough() {
        let identity = ArtistIdentityMatcher.decide(
            name: "Boston", libraryAlbumTitles: ["Boston", "The Best of Boston"],
            candidates: [candidate("b1", "Boston", ["Boston", "Best of Boston"])],
            rejected: [])
        XCTAssertEqual(identity, .uncertain([ArtistIdentityCandidate(musicBrainzID: "b1", name: "Boston",
                                                                     releaseTitles: ["Boston", "Best of Boston"])]))
    }

    func testNoNameMatchIsNotFound() {
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Massive Attack", libraryAlbumTitles: ["Mezzanine"],
            candidates: [candidate("x", "Massive Attack Tribute Band", ["Mezzanine"])], rejected: []),
            .notFound)
        XCTAssertEqual(ArtistIdentityMatcher.decide(name: "Massive Attack", libraryAlbumTitles: [],
                                                    candidates: [], rejected: []), .notFound)
    }

    func testRejectedIDIsSkipped() {
        let identity = ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [candidate("a1", "Air", ["Moon Safari"]), candidate("a2", "Air", ["Moon Safari"])],
            rejected: ["a1"])
        XCTAssertEqual(identity, .confirmed(musicBrainzID: "a2", wikidataID: nil))

        // The only name match rejected: nobody left to be them.
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [candidate("a1", "Air", ["Moon Safari"])], rejected: ["a1"]), .notFound)
    }

    func testUncertainKeepsAtMostFiveConfidentFirst() {
        var candidates = (1...6).map { candidate("n\($0)", "Air", ["Other \($0)"]) }
        candidates.append(candidate("c1", "Air", ["Moon Safari"]))
        candidates.append(candidate("c2", "Air", ["Talkie Walkie", "Moon Safari"]))
        let identity = ArtistIdentityMatcher.decide(name: "Air", libraryAlbumTitles: ["Moon Safari"],
                                                    candidates: candidates, rejected: [])
        guard case .uncertain(let held) = identity else { return XCTFail("\(identity)") }
        XCTAssertEqual(held.map(\.musicBrainzID), ["c1", "c2", "n1", "n2", "n3"])
    }
}
