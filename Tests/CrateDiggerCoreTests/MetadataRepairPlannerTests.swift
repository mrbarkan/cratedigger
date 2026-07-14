#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class MetadataRepairPlannerTests: XCTestCase {

    func testFillsMissingFieldsFromProbe() {
        let stored = ConversionMetadata(title: "Song", artist: "Artist", trackNumber: nil, year: nil)
        let probed = ConversionMetadata(title: "Song", artist: "Artist", trackNumber: 5, trackTotal: 12, year: 1994, genre: "House")

        let outcome = MetadataRepairPlanner.repair(stored: stored, probed: probed)

        XCTAssertEqual(outcome.metadata.trackNumber, 5)
        XCTAssertEqual(outcome.metadata.trackTotal, 12)
        XCTAssertEqual(outcome.metadata.year, 1994)
        XCTAssertEqual(outcome.metadata.genre, "House")
        XCTAssertEqual(Set(outcome.filledFields), [.trackNumber, .trackTotal, .year, .genre])
        XCTAssertTrue(outcome.conflicts.isEmpty)
    }

    func testConflictKeepsStoredValueAndReportsBoth() {
        let stored = ConversionMetadata(title: "My Edited Title", trackNumber: 3, year: 1999)
        let probed = ConversionMetadata(title: "Original Title", trackNumber: 3, year: 2001)

        let outcome = MetadataRepairPlanner.repair(stored: stored, probed: probed)

        XCTAssertEqual(outcome.metadata.title, "My Edited Title")
        XCTAssertEqual(outcome.metadata.year, 1999)
        XCTAssertEqual(Set(outcome.conflicts.map(\.field)), [.title, .year])
        let yearConflict = outcome.conflicts.first { $0.field == .year }
        XCTAssertEqual(yearConflict?.storedValue, "1999")
        XCTAssertEqual(yearConflict?.probedValue, "2001")
        XCTAssertTrue(outcome.filledFields.isEmpty)
    }

    func testIdenticalMetadataIsNoOp() {
        let metadata = ConversionMetadata(title: "Same", artist: "Same", trackNumber: 1, year: 2020)
        let outcome = MetadataRepairPlanner.repair(stored: metadata, probed: metadata)
        XCTAssertTrue(outcome.filledFields.isEmpty)
        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertEqual(outcome.metadata, metadata)
    }

    func testProbeBlanksNeverEraseStoredValues() {
        let stored = ConversionMetadata(title: "Kept", trackNumber: 7, genre: "Techno")
        let probed = ConversionMetadata(title: nil, trackNumber: nil, genre: nil)
        let outcome = MetadataRepairPlanner.repair(stored: stored, probed: probed)
        XCTAssertEqual(outcome.metadata, stored)
        XCTAssertTrue(outcome.filledFields.isEmpty)
        XCTAssertTrue(outcome.conflicts.isEmpty)
    }

    func testWhitespaceOnlyDifferenceIsNotAConflict() {
        let stored = ConversionMetadata(title: "Song Title ")
        let probed = ConversionMetadata(title: "Song Title")
        let outcome = MetadataRepairPlanner.repair(stored: stored, probed: probed)
        XCTAssertTrue(outcome.conflicts.isEmpty)
    }

    func testAdoptAppliesOnlyChosenFields() {
        let stored = ConversionMetadata(title: "Mine", trackNumber: 3, year: 1999)
        let probed = ConversionMetadata(title: "Theirs", trackNumber: 4, year: 2001)

        let adopted = MetadataRepairPlanner.adopt([.year], from: probed, into: stored)

        XCTAssertEqual(adopted.year, 2001)      // chosen
        XCTAssertEqual(adopted.title, "Mine")   // untouched
        XCTAssertEqual(adopted.trackNumber, 3)  // untouched
    }

    func testNeedsRepairOnlyWhenTrackNumberMissing() {
        XCTAssertTrue(MetadataRepairPlanner.needsRepair(ConversionMetadata(title: "T", trackNumber: nil)))
        // Missing year/disc alone is common and legitimate — not a candidate.
        XCTAssertFalse(MetadataRepairPlanner.needsRepair(ConversionMetadata(title: "T", trackNumber: 2, year: nil)))
    }

    // MARK: - Duplicated numbers within an album

    private func loadedTrack(_ name: String, disc: Int? = nil, number: Int?) -> LoadedTrack {
        let track = AudioTrack(fileURL: URL(fileURLWithPath: "/m/\(name).flac"), title: name,
                               trackNumber: number, discNumber: disc)
        return LoadedTrack(track: track,
                           metadata: ConversionMetadata(title: name, trackNumber: number, discNumber: disc))
    }

    func testAllSameNumberAlbumFlagsEveryTrack() {
        let tracks = (1...4).map { loadedTrack("t\($0)", number: 11) }
        let flagged = MetadataRepairPlanner.duplicatedNumberTrackIDs(in: tracks)
        XCTAssertEqual(flagged, Set(tracks.map { $0.track.id }))
    }

    func testHealthyAlbumFlagsNothing() {
        let tracks = (1...4).map { loadedTrack("t\($0)", number: $0) }
        XCTAssertTrue(MetadataRepairPlanner.duplicatedNumberTrackIDs(in: tracks).isEmpty)
    }

    func testOnlyTheCollidingPairIsFlagged() {
        let tracks = [loadedTrack("a", number: 1), loadedTrack("b", number: 3), loadedTrack("c", number: 3)]
        let flagged = MetadataRepairPlanner.duplicatedNumberTrackIDs(in: tracks)
        XCTAssertEqual(flagged, Set([tracks[1].track.id, tracks[2].track.id]))
    }

    func testSameNumberOnDifferentDiscsIsNotADuplicate() {
        let tracks = [loadedTrack("d1t1", disc: 1, number: 1), loadedTrack("d2t1", disc: 2, number: 1)]
        XCTAssertTrue(MetadataRepairPlanner.duplicatedNumberTrackIDs(in: tracks).isEmpty)
    }

    func testMissingNumbersNeverCountAsDuplicates() {
        // Blanks are the OTHER candidacy signal (needsRepair) — two nils
        // colliding here would double-flag them for no reason.
        let tracks = [loadedTrack("a", number: nil), loadedTrack("b", number: nil)]
        XCTAssertTrue(MetadataRepairPlanner.duplicatedNumberTrackIDs(in: tracks).isEmpty)
    }
}
#endif
