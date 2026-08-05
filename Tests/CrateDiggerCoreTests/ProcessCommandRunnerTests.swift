import XCTest
@testable import CrateDiggerCore

final class ProcessCommandRunnerPathTests: XCTestCase {
    func testAugmentedPathIncludesHomebrewWhenBaseLacksIt() {
        let result = ProcessCommandRunner.augmentedPATH(
            "/usr/bin:/bin",
            additionalDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        )
        let dirs = result.split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "must add the Homebrew dir where deno/node live")
        XCTAssertTrue(dirs.contains("/usr/bin"))
        // No duplicates (/usr/bin and /bin appear in both base and additional).
        XCTAssertEqual(dirs.count, Set(dirs).count, "no duplicate PATH entries")
    }

    func testAugmentedPathHandlesEmptyBase() {
        let result = ProcessCommandRunner.augmentedPATH(nil, additionalDirectories: ["/opt/homebrew/bin"])
        XCTAssertEqual(result, "/opt/homebrew/bin")
    }
}

final class ProcessCommandRunnerTimeoutTests: XCTestCase {
    func testTimeoutKillsHungProcess() throws {
        let runner = ProcessCommandRunner(timeoutSeconds: 0.5)
        let start = Date()
        let output = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "timeout should fire long before sleep finishes")
        XCTAssertNotEqual(output.terminationStatus, 0, "a killed process must not report success")
    }

    func testWithoutTimeoutProcessRunsToCompletion() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ok"]
        )
        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}

/// Regression: a tag value carrying an embedded NUL used to abort the whole app.
/// `Process` runs `fileSystemRepresentation` over the launch path *and every
/// argument*, and that raises an Objective-C exception — which Swift `try` cannot
/// catch — instead of returning an error. See CrateDigger 1.1.1 crash on
/// com.cratedigger.tag-write.
final class ProcessCommandRunnerArgumentSafetyTests: XCTestCase {
    func testArgumentWithEmbeddedNULThrowsInsteadOfCrashing() {
        let runner = ProcessCommandRunner()
        XCTAssertThrowsError(
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["-metadata", "album=Green\u{0}Album"]
            )
        ) { error in
            guard case ConversionServiceError.unrepresentableArgument = error else {
                return XCTFail("expected unrepresentableArgument, got \(error)")
            }
        }
    }

    func testExecutablePathWithEmbeddedNULThrowsInsteadOfCrashing() {
        let runner = ProcessCommandRunner()
        XCTAssertThrowsError(
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/ec\u{0}ho"),
                arguments: []
            )
        )
    }

    func testOrdinaryArgumentsStillRun() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["Café 🎵 — Björk"]
        )
        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertTrue(output.standardOutput.contains("Björk"))
    }
}

final class MetadataTagSanitizationTests: XCTestCase {
    func testStripsNULFromTagValue() {
        XCTAssertEqual(MetadataNormalization.sanitizedTagValue("Rock\u{0}Pop"), "RockPop")
        XCTAssertEqual(MetadataNormalization.sanitizedTagValue("Album\u{0}"), "Album")
    }

    func testLeavesOrdinaryTextUntouched() {
        for value in ["Björk", "Café 🎵", "Two\nLines", "A/B", "Sigur Rós — ( )"] {
            XCTAssertEqual(MetadataNormalization.sanitizedTagValue(value), value)
        }
    }

    /// The tag writer must never hand a NUL through to ffmpeg's argument vector.
    func testMetadataEditorSanitizesArgumentsItBuilds() throws {
        let runner = RecordingCommandRunner()
        let editor = try MetadataEditorService(
            ffmpegExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            commandRunner: runner
        )
        var metadata = ConversionMetadata()
        metadata.title = "Track\u{0}One"
        metadata.artist = "Some\u{0}Artist"

        // The ffmpeg run is faked; the replaceItem afterwards is expected to fail.
        _ = try? editor.writeMetadata(to: URL(fileURLWithPath: "/tmp/nonexistent.flac"),
                                      metadata: metadata)

        XCTAssertFalse(runner.captured.isEmpty, "runner should have been invoked")
        for argument in runner.captured {
            XCTAssertFalse(argument.utf8.contains(0), "argument still carries a NUL: \(argument)")
        }
        XCTAssertTrue(runner.captured.contains("title=TrackOne"))
    }
}

private final class RecordingCommandRunner: CommandRunning {
    var captured: [String] = []
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        captured = arguments
        return CommandOutput(terminationStatus: 0, standardOutput: "", standardError: "")
    }
}
