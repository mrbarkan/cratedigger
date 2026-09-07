#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// fpcalc is a subprocess, so the parts worth testing are the argument vector
/// we hand it and what we make of what comes back. Both run against a fake
/// runner; nothing here spawns a process.
final class AudioFingerprintServiceTests: XCTestCase {

    private final class FakeRunner: CommandRunning {
        var output: CommandOutput
        private(set) var lastExecutable: URL?
        private(set) var lastArguments: [String] = []

        init(_ output: CommandOutput) { self.output = output }

        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
            lastExecutable = executableURL
            lastArguments = arguments
            return output
        }
    }

    private let fpcalc = URL(fileURLWithPath: "/usr/local/bin/fpcalc")
    private let file = URL(fileURLWithPath: "/Music/New Order/Technique/01 Fine Time.flac")

    private func ok(_ stdout: String) -> CommandOutput {
        CommandOutput(terminationStatus: 0, standardOutput: stdout, standardError: "")
    }

    // MARK: - Arguments

    func testArgumentsAskForJSONAndTheReferenceSampleLength() {
        let arguments = AudioFingerprintService.arguments(for: file)
        XCTAssertEqual(arguments, ["-json", "-length", "120", file.path])
    }

    func testArgumentsPassAnAbsolutePathSoNoOptionTerminatorIsNeeded() {
        // fpcalc rejects "--" as an unknown flag, so the path itself has to be
        // unambiguous. A file URL's path always is.
        let arguments = AudioFingerprintService.arguments(for: URL(fileURLWithPath: "/Music/-weird name.flac"))
        XCTAssertFalse(arguments.contains("--"))
        XCTAssertEqual(arguments.last, "/Music/-weird name.flac")
    }

    func testRunnerIsGivenTheConfiguredBinary() throws {
        let runner = FakeRunner(ok(#"{"duration":292.28,"fingerprint":"AQADtEmi"}"#))
        _ = try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)
        XCTAssertEqual(runner.lastExecutable, fpcalc)
        XCTAssertEqual(runner.lastArguments.last, file.path)
    }

    // MARK: - Parsing

    func testParsesDurationAndFingerprint() throws {
        let runner = FakeRunner(ok(#"{"duration":292.28,"fingerprint":"AQADtEmiRIkS"}"#))
        let result = try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)

        XCTAssertEqual(result.fileURL, file)
        XCTAssertEqual(result.fingerprint, "AQADtEmiRIkS")
        // AcoustID only accepts whole seconds, and 292.28 is 292, not 293.
        XCTAssertEqual(result.durationSeconds, 292)
    }

    func testDurationRoundsRatherThanTruncates() throws {
        let runner = FakeRunner(ok(#"{"duration":292.72,"fingerprint":"AQADtEmi"}"#))
        let result = try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)
        XCTAssertEqual(result.durationSeconds, 293)
    }

    func testNonZeroExitThrowsWithStderr() {
        let runner = FakeRunner(CommandOutput(
            terminationStatus: 2,
            standardOutput: "",
            standardError: "ERROR: couldn't open the file"
        ))
        XCTAssertThrowsError(try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)) { error in
            XCTAssertEqual(
                error as? AudioFingerprintError,
                .commandFailed(2, "ERROR: couldn't open the file")
            )
        }
    }

    func testGarbageOutputThrowsRatherThanCrashing() {
        let runner = FakeRunner(ok("not json at all"))
        XCTAssertThrowsError(try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)) { error in
            XCTAssertEqual(error as? AudioFingerprintError, .unreadableOutput)
        }
    }

    func testEmptyFingerprintIsRejectedRatherThanPostedToAcoustID() {
        let runner = FakeRunner(ok(#"{"duration":0,"fingerprint":""}"#))
        XCTAssertThrowsError(try AudioFingerprintService(fpcalcURL: fpcalc, runner: runner).fingerprint(file)) { error in
            XCTAssertEqual(error as? AudioFingerprintError, .emptyFingerprint)
        }
    }
}
#endif
