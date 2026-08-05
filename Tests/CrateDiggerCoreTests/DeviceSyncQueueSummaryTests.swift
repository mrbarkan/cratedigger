#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class DeviceSyncQueueSummaryTests: XCTestCase {

    private func entry(staged: Bool, name: String = "a") -> DeviceSyncQueueEntry {
        let track = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/\(name).flac"),
                               title: name, artist: "Artist", album: "Album",
                               durationSeconds: 120)
        return DeviceSyncQueueEntry(
            track: LoadedTrack(track: track, metadata: ConversionMetadata()),
            destinationRelativePath: "Artist/Album/\(name).m4a",
            isStaged: staged,
            sourceModifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testEmptyQueue() {
        let summary = DeviceSyncQueueSummary.make(entries: [], sizeOfStaged: { _ in nil },
                                                  sizeOfSource: { _ in nil })
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.headline, "Nothing queued")
        XCTAssertNil(summary.detail)
    }

    /// Staged entries occupy space on this Mac; copy-mode entries do not.
    func testStagedBytesCountOnlyStagedEntries() {
        let entries = [entry(staged: true, name: "a"), entry(staged: false, name: "b")]
        let summary = DeviceSyncQueueSummary.make(
            entries: entries,
            sizeOfStaged: { _ in 5_000_000 },
            sizeOfSource: { _ in 30_000_000 }
        )
        XCTAssertEqual(summary.stagedCount, 1)
        XCTAssertEqual(summary.copyCount, 1)
        XCTAssertEqual(summary.stagedBytes, 5_000_000, "copy-mode entries take no local space")
        XCTAssertEqual(summary.transferBytes, 35_000_000, "both still land on the device")
        XCTAssertEqual(summary.totalCount, 2)
    }

    /// A copy-mode entry with no source file will fail at sync time — that is
    /// worth surfacing before the device is plugged in.
    func testMissingCopySourceIsCounted() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: false)],
            sizeOfStaged: { _ in nil },
            sizeOfSource: { _ in nil }
        )
        XCTAssertEqual(summary.missingSourceCount, 1)
        XCTAssertEqual(summary.transferBytes, 0)
    }

    /// A staged entry's bake stands on its own, so a vanished source is not a
    /// failure for it and must not be reported as one.
    func testMissingSourceIsNotCountedForStagedEntries() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true)],
            sizeOfStaged: { _ in 1_000_000 },
            sizeOfSource: { _ in nil }
        )
        XCTAssertEqual(summary.missingSourceCount, 0)
        XCTAssertEqual(summary.transferBytes, 1_000_000)
    }

    func testHeadlineReportsCountAndTransferSize() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true, name: "a"), entry(staged: true, name: "b")],
            sizeOfStaged: { _ in 10_000_000 },
            sizeOfSource: { _ in nil }
        )
        XCTAssertTrue(summary.headline.hasPrefix("2 tracks · "), summary.headline)
    }

    func testHeadlineIsSingularForOneTrack() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true)],
            sizeOfStaged: { _ in 1_000_000 },
            sizeOfSource: { _ in nil }
        )
        XCTAssertTrue(summary.headline.contains("1 track ·"), summary.headline)
        XCTAssertFalse(summary.headline.contains("1 tracks"))
    }

    func testDetailDistinguishesMixedModes() {
        let mixed = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true, name: "a"), entry(staged: false, name: "b")],
            sizeOfStaged: { _ in 1_000_000 },
            sizeOfSource: { _ in 2_000_000 }
        )
        XCTAssertEqual(mixed.detail?.contains("1 converted, 1 as-is"), true, mixed.detail ?? "nil")

        let copyOnly = DeviceSyncQueueSummary.make(
            entries: [entry(staged: false)],
            sizeOfStaged: { _ in nil },
            sizeOfSource: { _ in 2_000_000 }
        )
        XCTAssertEqual(copyOnly.detail?.contains("copied from the originals"), true, copyOnly.detail ?? "nil")
        XCTAssertEqual(copyOnly.detail?.contains("staged on this Mac"), false,
                       "copy-mode stages nothing, so it must not claim local space")
    }

    func testByteLabelIsHumanReadable() {
        XCTAssertEqual(DeviceSyncQueueSummary.byteLabel(0), "0 MB")
        XCTAssertTrue(DeviceSyncQueueSummary.byteLabel(1_500_000_000).contains("GB"))
    }
}
#endif
