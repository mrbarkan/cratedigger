import XCTest
@testable import CrateDiggerCore

/// Who an artist is on MusicBrainz: the picture finder's match rule (a
/// fold-equal name plus telling album titles in common), applied to
/// MusicBrainz artists and their release groups.
final class ArtistIdentityMatcherTests: XCTestCase {
    private func candidate(_ id: String, _ name: String, _ titles: [String])
        -> (ArtistIdentityCandidate, releaseGroupTitles: [String]) {
        (ArtistIdentityCandidate(musicBrainzID: id, name: name), releaseGroupTitles: titles)
    }

    private func heldIDs(_ identity: ArtistProfile.Identity, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard case .uncertain(let held) = identity else {
            XCTFail("expected uncertain, got \(identity)", file: file, line: line)
            return []
        }
        return held.map(\.musicBrainzID)
    }

    func testOneConfidentIsConfirmed() {
        // The only act of the name: one telling title is enough.
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Massive Attack", libraryAlbumTitles: ["Mezzanine (Deluxe Edition)"],
            candidates: [candidate("ma", "Massive Attack", ["Blue Lines", "Mezzanine"]),
                         candidate("tribute", "Massive Attack Tribute", ["Mezzanine"])],
            rejected: []), .confirmed(musicBrainzID: "ma", wikidataID: nil))

        // Two acts of the name: the one sharing two telling titles is confirmed.
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Massive Attack", libraryAlbumTitles: ["Mezzanine (Deluxe Edition)", "Blue Lines"],
            candidates: [candidate("ma", "Massive Attack", ["Blue Lines", "Mezzanine"]),
                         candidate("other", "Massive Attack", ["Something Else", "Mezzanine"])],
            rejected: []), .confirmed(musicBrainzID: "ma", wikidataID: nil))
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
        XCTAssertEqual(heldIDs(identity), ["b1", "b2"])
        if case .uncertain(let held) = identity {
            XCTAssertEqual(held.first?.releaseTitles, ["Boston", "Don't Look Back", "Greatest Hits"])
        }

        // Two that both share a telling album are an ambiguity too, never a pick.
        XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [candidate("a1", "Air", ["Moon Safari"]), candidate("a2", "AIR", ["Moon Safari"])],
            rejected: [])), ["a1", "a2"])

        // Two acts of one name each sharing one real title: one title in
        // common is a coincidence when the name is shared.
        XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari", "Talkie Walkie"],
            candidates: [candidate("a1", "Air", ["Moon Safari", "Pocket Symphony"]),
                         candidate("a2", "Air", ["Talkie Walkie", "Something"])],
            rejected: [])), ["a1", "a2"])

        // Review I1: a prolific act whose albums did not reach the lookup, and
        // an obscure act of the same name sharing one title. One shared title
        // with a second act of the name about is not enough to pick it.
        XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari", "Talkie Walkie"],
            candidates: [candidate("famous", "Air", ["Kelly Watch the Stars", "Sexy Boy"]),
                         candidate("obscure", "Air", ["Moon Safari", "Basement Tapes"])],
            rejected: [])), ["famous", "obscure"])
    }

    /// Three underground acts called Abigail, each with a "Demo".
    func testGenericUndergroundTitlesNeverConfirm() {
        XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
            name: "Abigail", libraryAlbumTitles: ["Demo"],
            candidates: [candidate("ab1", "Abigail", ["Demo", "Intercourse & Lust"]),
                         candidate("ab2", "Abigail", ["Demo"]),
                         candidate("ab3", "Abigail", ["Demo", "Split"])],
            rejected: [])), ["ab1", "ab2", "ab3"])

        // Even alone, a numbered, generic or too-short title tells nobody apart.
        for title in ["III", "IV", "XII", "Demo 2008", "EP2", "Untitled #1", "Vol. 2", "Volume One", "Volume II",
                      "S/T", "EP", "Split", "Promo", "Christmas", "1984", "7\"", "Untitled"] {
            XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
                name: "Abigail", libraryAlbumTitles: [title],
                candidates: [candidate("ab1", "Abigail", [title])], rejected: [])), ["ab1"], title)
        }
        // Words that only look like numbers or generic stems still count.
        for title in ["Mix", "Demon Days", "Epic", "Volcano", "Splitting the Atom"] {
            XCTAssertEqual(ArtistIdentityMatcher.decide(
                name: "Abigail", libraryAlbumTitles: [title],
                candidates: [candidate("ab1", "Abigail", [title])], rejected: []),
                .confirmed(musicBrainzID: "ab1", wikidataID: nil), title)
        }
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
        // The rejected act was not confident: the evidence still stands for the other.
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari", "Talkie Walkie"],
            candidates: [candidate("a1", "Air", ["Something Else"]),
                         candidate("a2", "Air", ["Moon Safari", "Talkie Walkie"])],
            rejected: ["a1"]), .confirmed(musicBrainzID: "a2", wikidataID: nil))

        // The rejected act was confident on the same evidence: that evidence
        // was wrong once, so the survivor is shown, not picked.
        XCTAssertEqual(heldIDs(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari", "Talkie Walkie"],
            candidates: [candidate("a1", "Air", ["Moon Safari", "Talkie Walkie"]),
                         candidate("a2", "Air", ["Moon Safari", "Talkie Walkie"])],
            rejected: ["a1"])), ["a2"])

        // The only name match rejected: nobody left to be them.
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [candidate("a1", "Air", ["Moon Safari"])], rejected: ["a1"]), .notFound)
    }

    func testUncertainKeepsAtMostFiveConfidentFirst() {
        var candidates = (1...6).map { candidate("n\($0)", "Air", ["Other \($0)"]) }
        candidates.append(candidate("c1", "Air", ["Moon Safari", "Talkie Walkie"]))
        candidates.append(candidate("c2", "Air", ["Talkie Walkie", "Moon Safari"]))
        let identity = ArtistIdentityMatcher.decide(name: "Air", libraryAlbumTitles: ["Moon Safari", "Talkie Walkie"],
                                                    candidates: candidates, rejected: [])
        XCTAssertEqual(heldIDs(identity), ["c1", "c2", "n1", "n2", "n3"])
    }
}
