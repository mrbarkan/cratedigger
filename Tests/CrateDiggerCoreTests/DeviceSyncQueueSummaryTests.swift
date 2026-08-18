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

    // MARK: - Convert-mode queues (nothing is baked at queue time)

    /// A convert-mode device that hasn't baked yet must not claim its files are
    /// going over as-is — they get converted, and the queued size is the source
    /// size, which is not what lands on the device.
    func testUnbakedConvertQueueSaysSoAndMarksItsSizeApproximate() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: false, name: "a"), entry(staged: false, name: "b")],
            unstagedWillConvert: true,
            sizeOfStaged: { _ in nil },
            sizeOfSource: { _ in 30_000_000 }
        )
        XCTAssertEqual(summary.pendingConversionCount, 2)
        XCTAssertEqual(summary.detail?.contains("converts when you sync"), true, summary.detail ?? "nil")
        XCTAssertEqual(summary.detail?.contains("copied from the originals"), false, summary.detail ?? "nil")
        XCTAssertTrue(summary.headline.contains("~"), summary.headline)
    }

    /// Half-baked queue: the wording has to separate what is ready from what
    /// still needs converting, not call the remainder "as-is".
    func testPartlyBakedConvertQueueCountsWhatIsLeft() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true, name: "a"), entry(staged: false, name: "b")],
            unstagedWillConvert: true,
            sizeOfStaged: { _ in 5_000_000 },
            sizeOfSource: { _ in 30_000_000 }
        )
        XCTAssertEqual(summary.pendingConversionCount, 1)
        XCTAssertEqual(summary.detail?.contains("1 converted, 1 not yet"), true, summary.detail ?? "nil")
    }

    /// Once everything is baked there is nothing left to convert, so CONVERT NOW
    /// has no work and the size is exact again.
    func testFullyBakedConvertQueueHasNothingPending() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: true, name: "a")],
            unstagedWillConvert: true,
            sizeOfStaged: { _ in 5_000_000 },
            sizeOfSource: { _ in 30_000_000 }
        )
        XCTAssertEqual(summary.pendingConversionCount, 0)
        XCTAssertEqual(summary.detail?.contains("converted, ready to copy"), true, summary.detail ?? "nil")
        XCTAssertFalse(summary.headline.contains("~"), summary.headline)
    }

    /// A copy-mode device never converts, so unbaked entries are exactly what
    /// they say: originals, exact size.
    func testCopyModeQueueIsUnaffected() {
        let summary = DeviceSyncQueueSummary.make(
            entries: [entry(staged: false, name: "a")],
            sizeOfStaged: { _ in nil },
            sizeOfSource: { _ in 30_000_000 }
        )
        XCTAssertEqual(summary.pendingConversionCount, 0)
        XCTAssertEqual(summary.detail?.contains("copied from the originals"), true, summary.detail ?? "nil")
        XCTAssertFalse(summary.headline.contains("~"), summary.headline)
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
