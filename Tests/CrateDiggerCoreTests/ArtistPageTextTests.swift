import XCTest
@testable import CrateDiggerCore

/// The words the artist page prints from a profile and a library summary.
final class ArtistPageTextTests: XCTestCase {

    func testFactsLineReadsKindOriginAndYears() {
        let facts = ArtistFacts(kind: "Group", origin: "Bristol, England", begin: "1991")
        XCTAssertEqual(ArtistPageText.factsLine(facts), "Band · Bristol, England · 1991 to now")
    }

    func testFactsLineSkipsWhatIsMissing() {
        XCTAssertEqual(ArtistPageText.factsLine(ArtistFacts(kind: "Person")), "Person")
        XCTAssertEqual(ArtistPageText.factsLine(ArtistFacts(origin: "Reykjavík, Iceland")), "Reykjavík, Iceland")
        XCTAssertEqual(ArtistPageText.factsLine(ArtistFacts(begin: "1970", end: "1980")), "1970 to 1980")
        XCTAssertNil(ArtistPageText.factsLine(ArtistFacts()))
        XCTAssertNil(ArtistPageText.factsLine(ArtistFacts(kind: " ", origin: "")), "blank fields print nothing")
    }

    func testKindsNameTheMusicBrainzTypes() {
        XCTAssertEqual(ArtistPageText.kind("Group"), "Band")
        XCTAssertEqual(ArtistPageText.kind("Person"), "Person")
        XCTAssertEqual(ArtistPageText.kind("Orchestra"), "Orchestra")
        XCTAssertEqual(ArtistPageText.kind("Choir"), "Choir")
        XCTAssertEqual(ArtistPageText.kind("Character"), "Character")
        XCTAssertNil(ArtistPageText.kind(nil))
    }

    func testYearsOnlyAnEnd() {
        XCTAssertEqual(ArtistPageText.years(begin: nil, end: "1999"), "until 1999")
        XCTAssertNil(ArtistPageText.years(begin: nil, end: nil))
    }

    func testMemberYears() {
        XCTAssertEqual(ArtistPageText.memberYears(ArtistMember(name: "Robert Del Naja", begin: "1988", isCurrent: true)),
                       "1988 to now")
        XCTAssertEqual(ArtistPageText.memberYears(ArtistMember(name: "Tricky", begin: "1988", end: "1995",
                                                              isCurrent: false)), "1988 to 1995")
        XCTAssertNil(ArtistPageText.memberYears(ArtistMember(name: "Unknown", isCurrent: true)))
        XCTAssertEqual(ArtistPageText.memberYears(ArtistMember(name: "Left", end: "2001", isCurrent: false)),
                       "until 2001")
    }

    func testFormatsSayMostlyWhenOneDominates() {
        var summary = ArtistLibrarySummary(trackCount: 10, dominantFormat: "FLAC", formatCounts: [("FLAC", 8), ("MP3", 2)])
        XCTAssertEqual(ArtistPageText.formats(summary), "Mostly FLAC")
        summary.formatCounts = [("FLAC", 10)]
        XCTAssertEqual(ArtistPageText.formats(summary), "FLAC", "every track one format: no 'mostly'")
    }

    func testFormatsListTheTopTwoOtherwise() {
        let summary = ArtistLibrarySummary(trackCount: 10, formatCounts: [("FLAC", 5), ("MP3", 4), ("AAC", 1)])
        XCTAssertEqual(ArtistPageText.formats(summary), "FLAC · MP3")
        XCTAssertNil(ArtistPageText.formats(ArtistLibrarySummary()))
    }

    func testDurationReadsHoursAndMinutes() {
        XCTAssertEqual(ArtistPageText.duration(3_125), "52 min")
        XCTAssertEqual(ArtistPageText.duration(3 * 3_600 + 4 * 60 + 10), "3 h 4 min")
        XCTAssertEqual(ArtistPageText.duration(7_200), "2 h")
        XCTAssertEqual(ArtistPageText.duration(20), "1 min", "anything under a minute still reads as a minute")
        XCTAssertNil(ArtistPageText.duration(0))
        XCTAssertNil(ArtistPageText.duration(.nan))
    }

    func testInitials() {
        XCTAssertEqual(ArtistPageText.initials("Massive Attack"), "MA")
        XCTAssertEqual(ArtistPageText.initials("björk"), "B")
        XCTAssertEqual(ArtistPageText.initials("Boards of Canada"), "BO")
        XCTAssertEqual(ArtistPageText.initials("!!!"), "?")
        XCTAssertEqual(ArtistPageText.initials("  "), "?")
    }
}
