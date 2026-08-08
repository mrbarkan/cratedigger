#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// FIX TAGS over a whole library used to put ffmpeg's entire per-stream dump
/// into the failure alert — once per failed file — and the sheet ran off the
/// bottom of the screen. The alert shows `failureReason` now, so it has to pull
/// the one line that says what went wrong out of a very noisy log.
final class MetadataEditorFailureReasonTests: XCTestCase {
    private func reason(_ stderr: String) -> String {
        MetadataEditorService.failureReason(
            CommandOutput(terminationStatus: 1, standardOutput: "", standardError: stderr))
    }

    /// Trimmed from a real failure: an MP3 whose "PNG" cover is actually JPEG.
    func testPicksTheDiagnosisOutOfAFullFfmpegDump() {
        let log = """
        Input #0, mp3, from '/Volumes/MUSIC/Big Thief/05 - Open Desert.mp3':
          Metadata:
            title           : Open Desert
            artist          : Big Thief
            TBPM            : 124
          Duration: 00:03:47.53, start: 0.025056, bitrate: 136 kb/s
          Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, stereo, fltp, 128 kb/s
          Stream #0:1: Video: png, none, 90k tbr, 90k tbn (attached pic)
        Stream mapping:
          Stream #0:1 -> #0:0 (copy)
          Stream #0:0 -> #0:1 (copy)
        [mp3 @ 0x151e0a1c0] dimensions not set
        [out#0/mp3 @ 0x600003f4c780] Could not write header (incorrect codec parameters ?): Invalid argument
        Conversion failed!
        """
        XCTAssertEqual(reason(log),
                       "[out#0/mp3 @ 0x600003f4c780] Could not write header (incorrect codec parameters ?): Invalid argument")
    }

    func testNeverReportsFfmpegsEpitaphAsTheDiagnosis() {
        let log = """
        [png @ 0x11ee04ac0] Invalid PNG signature 0xFFD8FFE000104A46.
        Conversion failed!
        """
        XCTAssertEqual(reason(log), "[png @ 0x11ee04ac0] Invalid PNG signature 0xFFD8FFE000104A46.")
    }

    func testFallsBackToTheLastLine() {
        XCTAssertEqual(reason("something happened\nand then it stopped"), "and then it stopped")
        XCTAssertEqual(reason(""), "ffmpeg failed with no output.")
    }

    /// One alert line per file — a runaway log can't be allowed to set the width.
    func testTruncatesRunawayLines() {
        let long = "Error: " + String(repeating: "x", count: 500)
        let out = reason(long)
        XCTAssertEqual(out.count, 201)          // 200 + the ellipsis
        XCTAssertTrue(out.hasSuffix("…"))
    }
}
#endif
