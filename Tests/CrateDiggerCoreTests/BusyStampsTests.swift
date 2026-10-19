#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The decidable halves of the app's start and finish sites (spec §3.1): how
/// each job's tally becomes an outcome, and the words its scene prints. The
/// sites themselves stay in the view model; what they decide lives here.
final class BusyStampsTests: XCTestCase {

    // MARK: Outcomes

    func testRipOutcome() {
        XCTAssertEqual(BusyOutcome.rip(cancelled: true, failedTracks: 0), .cancelled)
        XCTAssertEqual(BusyOutcome.rip(cancelled: true, failedTracks: 3), .cancelled, "a cancel is never a failure")
        XCTAssertEqual(BusyOutcome.rip(cancelled: false, failedTracks: 1), .failed,
                       "the app says Rip Failed, so no check may blink")
        XCTAssertEqual(BusyOutcome.rip(cancelled: false, failedTracks: 0), .completed)
    }

    func testThrownErrorOutcome() {
        struct Other: Error {}
        XCTAssertEqual(BusyOutcome.thrown(CancellationError()), .cancelled)
        XCTAssertEqual(BusyOutcome.thrown(Other()), .failed)
    }

    func testConversionOutcome() {
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 4, failed: 0, cancelled: 2), .cancelled)
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 0, failed: 1, cancelled: 1), .cancelled,
                       "a cancel outranks the failures it left behind")
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 0, failed: 3, cancelled: 0), .failed)
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 2, failed: 1, cancelled: 0), .completed,
                       "partial success completes; the summary sheet carries the errors")
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 5, failed: 0, cancelled: 0), .completed)
        XCTAssertEqual(BusyOutcome.conversion(succeeded: 0, failed: 0, cancelled: 0), .completed,
                       "an empty batch failed nothing")
    }

    func testCopyTransferOutcomeReadsTheCancelFlag() {
        // The copy loop counts a cancelled item as a failure, so only the flag
        // tells a cancelled partial copy from a finished one.
        XCTAssertEqual(BusyOutcome.copyTransfer(wasCancelled: true, succeeded: 3, failed: 2), .cancelled)
        XCTAssertEqual(BusyOutcome.copyTransfer(wasCancelled: false, succeeded: 0, failed: 2), .failed)
        XCTAssertEqual(BusyOutcome.copyTransfer(wasCancelled: false, succeeded: 3, failed: 2), .completed)
        XCTAssertEqual(BusyOutcome.copyTransfer(wasCancelled: false, succeeded: 3, failed: 0), .completed)
    }

    func testSyncOutcome() {
        XCTAssertEqual(BusyOutcome.sync(failed: 4, total: 4), .failed)
        XCTAssertEqual(BusyOutcome.sync(failed: 3, total: 4), .completed)
        XCTAssertEqual(BusyOutcome.sync(failed: 0, total: 0), .completed, "nothing to do failed nothing")
    }

    func testScanOutcome() {
        XCTAssertEqual(BusyOutcome.scan(found: 0), .failed, "nothing found is no success to blink")
        XCTAssertEqual(BusyOutcome.scan(found: 12), .completed)
    }

    func testDownloadOutcome() {
        XCTAssertEqual(BusyOutcome.download(succeeded: true, cancelled: false), .completed)
        XCTAssertEqual(BusyOutcome.download(succeeded: false, cancelled: true), .cancelled)
        XCTAssertEqual(BusyOutcome.download(succeeded: false, cancelled: false), .failed)
        XCTAssertEqual(BusyOutcome.download(succeeded: true, cancelled: true), .completed,
                       "a cancel that lost the race to the finished file still delivered it")
    }

    // MARK: Labels

    func testConversionLabelsPickTheMostCommonSourceExtension() {
        let labels = BusyLabels.conversion(sourceExtensions: ["flac", "wav", "FLAC", "aiff", "flac"], target: .mp3)
        XCTAssertEqual(labels.source, "FLAC", "case-insensitive count")
        XCTAssertEqual(labels.target, "MP3")
    }

    func testConversionLabelsBreakTiesByFirstAppearance() {
        XCTAssertEqual(BusyLabels.conversion(sourceExtensions: ["wav", "flac", "flac", "wav"], target: .aac).source, "WAV")
        XCTAssertEqual(BusyLabels.conversion(sourceExtensions: ["flac", "wav", "wav", "flac"], target: .aac).source, "FLAC")
    }

    func testConversionLabelsWithNoExtensionHaveNoSource() {
        XCTAssertNil(BusyLabels.conversion(sourceExtensions: [], target: .flac).source)
        XCTAssertNil(BusyLabels.conversion(sourceExtensions: ["", " "], target: .flac).source)
        XCTAssertEqual(BusyLabels.conversion(sourceExtensions: ["", "wav"], target: .flac).source, "WAV",
                       "an extensionless file does not outvote a real one")
    }

    func testConversionTargetIsTheFormatsShortName() {
        let expected: [OutputFormat: String] = [.mp3: "MP3", .aac: "AAC", .alac: "ALAC", .flac: "FLAC",
                                                .wav: "WAV", .aiff: "AIFF", .ogg: "OGG", .opus: "OPUS"]
        for format in OutputFormat.allCases {
            XCTAssertEqual(BusyLabels.conversion(sourceExtensions: ["wav"], target: format).target,
                           expected[format], "\(format)")
        }
    }

    func testDownloadLabelIsTheChannelOrStream() {
        XCTAssertEqual(BusyLabels.download(channel: "Boiler Room").source, "BOILER ROOM")
        XCTAssertEqual(BusyLabels.download(channel: "").source, "STREAM")
        XCTAssertEqual(BusyLabels.download(channel: "   ").source, "STREAM")
        XCTAssertEqual(BusyLabels.download(channel: nil).source, "STREAM")
        XCTAssertNil(BusyLabels.download(channel: "KEXP").target)
    }
}
#endif
