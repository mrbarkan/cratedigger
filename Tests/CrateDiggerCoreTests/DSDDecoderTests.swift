// Tests/CrateDiggerCoreTests/DSDDecoderTests.swift
import XCTest
@testable import CrateDiggerCore

private struct FakeRunner: CommandRunning {
    let status: Int32
    let stderr: String
    var captured: (@Sendable (URL, [String]) -> Void)?
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        captured?(executableURL, arguments)
        return CommandOutput(terminationStatus: status, standardOutput: "", standardError: stderr)
    }
}

final class DSDDecoderTests: XCTestCase {
    private let ffmpeg = URL(fileURLWithPath: "/usr/bin/ffmpeg")

    func testCanDecodeOnlyDSD() {
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg)
        XCTAssertTrue(d.canDecode(URL(fileURLWithPath: "/x/a.dsf")))
        XCTAssertTrue(d.canDecode(URL(fileURLWithPath: "/x/a.DFF")))
        XCTAssertFalse(d.canDecode(URL(fileURLWithPath: "/x/a.flac")))
    }

    func testDecodeArgumentsAre24BitCAFAtTargetRate() {
        let args = FFmpegDSDDecoder.decodeArguments(
            input: URL(fileURLWithPath: "/in.dsf"),
            output: URL(fileURLWithPath: "/out.caf"),
            sampleRateHz: 88_200)
        // -y -i /in.dsf -map 0:a:0 -c:a pcm_s24le -ar 88200 -f caf /out.caf
        XCTAssertEqual(args, [
            "-y", "-i", "/in.dsf", "-map", "0:a:0",
            "-c:a", "pcm_s24le", "-ar", "88200", "-f", "caf", "/out.caf",
        ])
    }

    func testDecodeSuccessReturnsTempURL() {
        let runner = FakeRunner(status: 0, stderr: "", captured: nil)
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg, commandRunner: runner)
        let exp = expectation(description: "decode")
        var out: URL?
        d.decode(URL(fileURLWithPath: "/x/a.dsf")) { result in
            if case .success(let url) = result { out = url }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(out?.pathExtension, "caf")
        XCTAssertTrue(out?.path.hasPrefix(FileManager.default.temporaryDirectory.path) ?? false)
    }

    func testDecodeFailurePropagatesError() {
        let runner = FakeRunner(status: 1, stderr: "boom", captured: nil)
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg, commandRunner: runner)
        let exp = expectation(description: "decode")
        var failed = false
        d.decode(URL(fileURLWithPath: "/x/a.dsf")) { result in
            if case .failure = result { failed = true }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(failed)
    }
}
