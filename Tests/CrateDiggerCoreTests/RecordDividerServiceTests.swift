import XCTest
@testable import CrateDiggerCore

final class RecordDividerServiceTests: XCTestCase {

    final class FakeRunner: CommandRunning {
        var output: CommandOutput
        private(set) var lastArgs: [String] = []
        init(_ o: CommandOutput) { output = o }
        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
            lastArgs = arguments
            return output
        }
    }

    private let ffmpeg = URL(fileURLWithPath: "/bin/ffmpeg")
    private let file = URL(fileURLWithPath: "/tmp/sideA.aiff")

    private func line(_ token: String, _ t: Double, dur: Double? = nil) -> String {
        var s = "[silencedetect @ 0x10] \(token): \(t)"
        if let dur { s += " | silence_duration: \(dur)" }
        return s
    }

    // MARK: - arguments

    func testArgumentsUseConservativeDefaults() {
        let args = RecordDividerService.arguments(fileURL: file)
        XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], file.path)
        let af = args[args.firstIndex(of: "-af")! + 1]
        XCTAssertEqual(af, "silencedetect=noise=-38dB:d=2.00")
        XCTAssertEqual(Array(args.suffix(3)), ["-f", "null", "-"])
    }

    func testSliderMapsToSpecRanges() {
        let aggressive = RecordDetectionSensitivity.fromSlider(1)
        XCTAssertEqual(aggressive.noiseFloorDb, -30, accuracy: 0.001)
        XCTAssertEqual(aggressive.minSilenceSeconds, 1.2, accuracy: 0.001)
        let gentle = RecordDetectionSensitivity.fromSlider(0)
        XCTAssertEqual(gentle.noiseFloorDb, -42, accuracy: 0.001)
        XCTAssertEqual(gentle.minSilenceSeconds, 2.8, accuracy: 0.001)
    }

    // MARK: - derivation

    /// Lead-in + run-out grooves are dropped; interior gaps cut at the midpoint.
    func testDerivesTracksDroppingLeadInAndRunOut() {
        let log = [
            line("silence_start", 0),      line("silence_end", 3.0, dur: 3.0),
            line("silence_start", 180),    line("silence_end", 182, dur: 2.0),
            line("silence_start", 400),    line("silence_end", 402.5, dur: 2.5),
            line("silence_start", 595),    line("silence_end", 600, dur: 5.0)
        ].joined(separator: "\n")

        let m = RecordDividerService.markers(fromSilenceLog: log, totalDuration: 600)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[0].startSeconds, 3.0, accuracy: 0.001)   // after lead-in
        XCTAssertEqual(m[0].endSeconds, 181, accuracy: 0.001)     // midpoint of [180,182]
        XCTAssertEqual(m[1].startSeconds, 181, accuracy: 0.001)
        XCTAssertEqual(m[1].endSeconds, 401.25, accuracy: 0.001)  // midpoint of [400,402.5]
        XCTAssertEqual(m[2].startSeconds, 401.25, accuracy: 0.001)
        XCTAssertEqual(m[2].endSeconds, 595, accuracy: 0.001)     // before run-out
        XCTAssertEqual(m.map(\.title), ["Track 01", "Track 02", "Track 03"])
    }

    /// A quiet blip that would carve out a <30s sliver gets absorbed (protect long
    /// songs / suppress false splits).
    func testShortSegmentMergedIntoNeighbour() {
        let log = [
            line("silence_start", 0),    line("silence_end", 3.0),
            line("silence_start", 180),  line("silence_end", 182),   // mid 181
            line("silence_start", 184),  line("silence_end", 186),   // mid 185 → 4s sliver
            line("silence_start", 400),  line("silence_end", 402),   // mid 401
            line("silence_start", 595),  line("silence_end", 600)
        ].joined(separator: "\n")

        let m = RecordDividerService.markers(fromSilenceLog: log, totalDuration: 600)
        XCTAssertEqual(m.count, 3, "the 4s sliver between 181 and 185 should merge away")
        XCTAssertEqual(m[0].startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(m[0].endSeconds, 185, accuracy: 0.001)   // grew to absorb the sliver
        XCTAssertEqual(m[1].startSeconds, 185, accuracy: 0.001)
    }

    func testNoSilencesYieldsSingleWholeFileTrack() {
        let m = RecordDividerService.markers(fromSilenceLog: "", totalDuration: 300)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(m[0].endSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(m[0].title, "Track 01")
    }

    func testOnlyEdgeSilencesYieldSingleTrimmedTrack() {
        let log = [
            line("silence_start", 0),    line("silence_end", 2.5),
            line("silence_start", 298),  line("silence_end", 300)
        ].joined(separator: "\n")
        let m = RecordDividerService.markers(fromSilenceLog: log, totalDuration: 300)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].startSeconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(m[0].endSeconds, 298, accuracy: 0.001)
    }

    /// File ends mid-silence: a dangling silence_start (no silence_end) is treated
    /// as a run-out to EOF and dropped.
    func testDanglingSilenceStartTreatedAsRunOut() {
        let log = [
            line("silence_start", 0),    line("silence_end", 3.0),
            line("silence_start", 200),  line("silence_end", 202),
            line("silence_start", 595)   // no closing end
        ].joined(separator: "\n")
        let m = RecordDividerService.markers(fromSilenceLog: log, totalDuration: 600)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.last!.endSeconds, 595, accuracy: 0.001)
    }

    // MARK: - detect (process integration)

    func testDetectParsesStderr() throws {
        let log = [line("silence_start", 200), line("silence_end", 202)].joined(separator: "\n")
        let runner = FakeRunner(CommandOutput(terminationStatus: 0, standardOutput: "", standardError: log))
        let svc = RecordDividerService(ffmpegURL: ffmpeg, runner: runner)
        let m = try svc.detect(fileURL: file, totalDuration: 600)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(runner.lastArgs[runner.lastArgs.firstIndex(of: "-i")! + 1], file.path)
    }

    func testDetectThrowsOnZeroDuration() {
        let svc = RecordDividerService(ffmpegURL: ffmpeg,
                                       runner: FakeRunner(CommandOutput(terminationStatus: 0, standardOutput: "", standardError: "")))
        XCTAssertThrowsError(try svc.detect(fileURL: file, totalDuration: 0)) {
            XCTAssertEqual($0 as? RecordDividerError, .noAudioDuration)
        }
    }

    func testDetectThrowsOnCommandFailure() {
        let runner = FakeRunner(CommandOutput(terminationStatus: 1, standardOutput: "", standardError: "boom"))
        let svc = RecordDividerService(ffmpegURL: ffmpeg, runner: runner)
        XCTAssertThrowsError(try svc.detect(fileURL: file, totalDuration: 600)) {
            XCTAssertEqual($0 as? RecordDividerError, .commandFailed(1, "boom"))
        }
    }
}
