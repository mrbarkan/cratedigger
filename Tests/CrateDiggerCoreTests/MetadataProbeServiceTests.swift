#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class MetadataProbeServiceTests: XCTestCase {
    func testProbeParsesTagsAndArtworkDisposition() throws {
        let json = """
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "audio",
              "disposition": { "attached_pic": 0 },
              "tags": { "language": "und" }
            },
            {
              "index": 1,
              "codec_type": "video",
              "disposition": { "attached_pic": 1 },
              "tags": { "comment": "Cover (front)" }
            }
          ],
          "format": {
            "tags": {
              "ARTIST": "Thom Yorke",
              "ALBUM": "The Eraser RMXS [Japan]"
            }
          }
        }
        """

        try withTemporaryDirectory(prefix: "CrateDiggerMetadataProbeTests") { temporaryDirectory in
            let fakeFFprobeURL = try writeExecutableStub(
                named: "ffprobe",
                contents: "#!/bin/sh\necho ffprobe stub\n",
                in: temporaryDirectory
            )

            let service = try MetadataProbeService(
                ffprobeExecutableURL: fakeFFprobeURL,
                commandRunner: FixedOutputCommandRunner(
                    output: CommandOutput(terminationStatus: 0, standardOutput: json, standardError: "")
                ),
                fileManager: FileManager.default
            )

            let metadata = try service.probe(url: temporaryDirectory.appendingPathComponent("sample.flac"))

            XCTAssertEqual(metadata.formatTags["ARTIST"], "Thom Yorke")
            XCTAssertEqual(metadata.formatTags["ALBUM"], "The Eraser RMXS [Japan]")
            XCTAssertEqual(metadata.streams.count, 2)
        }
    }


    /// Regression: tracks showed a dash instead of a time because ffprobe's
    /// duration was never parsed, leaving AVFoundation's 0 as the only answer.
    func testProbeParsesFormatAndStreamDuration() throws {
        let json = """
        {
          "streams": [
            { "index": 0, "codec_type": "audio", "duration": "245.373062" }
          ],
          "format": { "duration": "245.400000", "bit_rate": "1004000" }
        }
        """
        let metadata = try probe(json)
        XCTAssertEqual(metadata.formatDurationSeconds ?? 0, 245.4, accuracy: 0.001)
        XCTAssertEqual(metadata.primaryAudioStream?.durationSeconds ?? 0, 245.373062, accuracy: 0.001)
        XCTAssertEqual(metadata.resolvedDurationSeconds ?? 0, 245.4, accuracy: 0.001)
    }

    func testResolvedDurationFallsBackToAudioStreamWhenContainerHasNone() throws {
        let json = """
        {
          "streams": [
            { "index": 0, "codec_type": "audio", "duration": "180.5" }
          ],
          "format": { "duration": "N/A" }
        }
        """
        let metadata = try probe(json)
        XCTAssertNil(metadata.formatDurationSeconds)
        XCTAssertEqual(metadata.resolvedDurationSeconds ?? 0, 180.5, accuracy: 0.001)
    }

    func testResolvedDurationIsNilWhenNothingReportsOne() throws {
        let json = """
        { "streams": [ { "index": 0, "codec_type": "audio" } ], "format": {} }
        """
        XCTAssertNil(try probe(json).resolvedDurationSeconds)
    }

    /// A zero or negative duration is as useless as a missing one.
    func testResolvedDurationRejectsZero() throws {
        let json = """
        {
          "streams": [ { "index": 0, "codec_type": "audio", "duration": "0.000000" } ],
          "format": { "duration": "0" }
        }
        """
        XCTAssertNil(try probe(json).resolvedDurationSeconds)
    }

    private func probe(_ json: String) throws -> ProbedMetadata {
        var result: ProbedMetadata!
        try withTemporaryDirectory(prefix: "CrateDiggerProbeDuration") { dir in
            let stub = try writeExecutableStub(named: "ffprobe",
                                               contents: "#!/bin/sh\necho stub\n",
                                               in: dir)
            let service = try MetadataProbeService(
                ffprobeExecutableURL: stub,
                commandRunner: FixedOutputCommandRunner(
                    output: CommandOutput(terminationStatus: 0, standardOutput: json, standardError: "")
                ),
                fileManager: FileManager.default
            )
            result = try service.probe(url: dir.appendingPathComponent("sample.flac"))
        }
        return result
    }

    func testProbeThrowsOnCommandFailure() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerMetadataProbeTests") { temporaryDirectory in
            let fakeFFprobeURL = try writeExecutableStub(
                named: "ffprobe",
                contents: "#!/bin/sh\necho ffprobe stub\n",
                in: temporaryDirectory
            )

            let service = try MetadataProbeService(
                ffprobeExecutableURL: fakeFFprobeURL,
                commandRunner: FixedOutputCommandRunner(
                    output: CommandOutput(terminationStatus: 1, standardOutput: "", standardError: "ffprobe failed")
                ),
                fileManager: FileManager.default
            )

            XCTAssertThrowsError(
                try service.probe(url: temporaryDirectory.appendingPathComponent("sample.flac"))
            )
        }
    }
}

private struct FixedOutputCommandRunner: CommandRunning {
    let output: CommandOutput

    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        output
    }
}
#endif
