#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Disc-ID hashing is pinned to vectors that MusicBrainz actually resolved —
/// a wrong hash is indistinguishable from "disc not in the database", so it has
/// to be checked against known-good answers rather than against itself.
final class CompactDiscTOCTests: XCTestCase {

    /// Pink Floyd — Atom Heart Mother. Read from a real disc; MusicBrainz
    /// returned 9 releases for this ID.
    private let atomHeartMother = CompactDiscTOC(
        firstTrack: 1, lastTrack: 5, leadoutBlock: 234673,
        trackOffsets: [150, 106826, 127134, 151806, 176087]
    )
    private let atomHeartMotherID = "DCzNRTeswcuOG8kdU4Zv5XaFlhQ-"

    /// Nirvana — Nevermind, MusicBrainz's own documented example TOC.
    private let nevermind = CompactDiscTOC(
        firstTrack: 1, lastTrack: 12, leadoutBlock: 267257,
        trackOffsets: [150, 22767, 41887, 58317, 72102, 91375,
                       104652, 115380, 132165, 143932, 159870, 174597]
    )
    private let nevermindID = "I5l9cCSFccLKFEKS.7wqSZAorPU-"

    func testDiscIDMatchesVerifiedVectors() {
        XCTAssertEqual(atomHeartMother.musicBrainzDiscID, atomHeartMotherID)
        XCTAssertEqual(nevermind.musicBrainzDiscID, nevermindID)
    }

    /// The 99 offset slots are part of the spec — truncating the payload to the
    /// real track count silently produces a different, unresolvable ID.
    func testDiscIDDependsOnEveryComponent() {
        let variants = [
            CompactDiscTOC(firstTrack: 2, lastTrack: 5, leadoutBlock: 234673,
                           trackOffsets: atomHeartMother.trackOffsets),
            CompactDiscTOC(firstTrack: 1, lastTrack: 6, leadoutBlock: 234673,
                           trackOffsets: atomHeartMother.trackOffsets),
            CompactDiscTOC(firstTrack: 1, lastTrack: 5, leadoutBlock: 234674,
                           trackOffsets: atomHeartMother.trackOffsets),
            CompactDiscTOC(firstTrack: 1, lastTrack: 5, leadoutBlock: 234673,
                           trackOffsets: [151, 106826, 127134, 151806, 176087])
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.musicBrainzDiscID, atomHeartMotherID)
        }
    }

    func testDiscIDIsURLSafe() {
        for id in [atomHeartMother.musicBrainzDiscID, nevermind.musicBrainzDiscID] {
            XCTAssertEqual(id.count, 28)
            XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")),
                         "base64 must be translated to the URL-safe alphabet")
        }
    }

    func testTOCParameterForDiscsMusicBrainzDoesNotKnow() {
        XCTAssertEqual(atomHeartMother.musicBrainzTOCParameter,
                       "1+5+234673+150+106826+127134+151806+176087")
    }

    // MARK: - Track geometry

    func testTrackLengthsRunToTheNextTrackThenTheLeadout() {
        XCTAssertEqual(atomHeartMother.trackLengthsInSectors,
                       [106676, 20308, 24672, 24281, 58586])
        XCTAssertEqual(atomHeartMother.trackCount, 5)
    }

    /// Atom Heart Mother's title suite is ~23:44, and 75 sectors = 1 second.
    func testTrackDurationsAreRealistic() {
        let durations = atomHeartMother.trackDurationsInSeconds
        XCTAssertEqual(durations[0], 1422.3, accuracy: 1.0)
        XCTAssertEqual(durations.reduce(0, +), 3127.0, accuracy: 2.0)
    }

    // MARK: - Parsing macOS's .TOC.plist

    func testParsesRealTOCPlistFromADisc() throws {
        let data = try fixture("AtomHeartMother.TOC.plist")
        let toc = try XCTUnwrap(CompactDiscTOC(tocPlistData: data))
        XCTAssertEqual(toc, atomHeartMother)
        XCTAssertEqual(toc.musicBrainzDiscID, atomHeartMotherID,
                       "the file macOS wrote must hash to the ID MusicBrainz resolved")
    }

    /// A mixed-mode disc's data track is not audio; counting it changes the ID.
    func testDataTracksAreExcluded() throws {
        let plist: [String: Any] = ["Sessions": [[
            "First Track": 1, "Last Track": 3, "Leadout Block": 200_000,
            "Track Array": [
                ["Point": 1, "Start Block": 150, "Data": false],
                ["Point": 2, "Start Block": 90_000, "Data": false],
                ["Point": 3, "Start Block": 150_000, "Data": true]
            ]
        ]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let toc = try XCTUnwrap(CompactDiscTOC(tocPlistData: data))
        XCTAssertEqual(toc.trackOffsets, [150, 90_000])
    }

    func testRejectsPlistsThatAreNotAnAudioTOC() throws {
        let bad: [[String: Any]] = [
            [:],
            ["Sessions": []],
            ["Sessions": [["First Track": 1, "Last Track": 2, "Leadout Block": 1000]]],   // no tracks
            ["Sessions": [["First Track": 1, "Last Track": 1, "Leadout Block": 0,
                           "Track Array": [["Point": 1, "Start Block": 150, "Data": false]]]]]  // no leadout
        ]
        for plist in bad {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            XCTAssertNil(CompactDiscTOC(tocPlistData: data), "should reject: \(plist)")
        }
        XCTAssertNil(CompactDiscTOC(tocPlistData: Data("not a plist".utf8)))
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
