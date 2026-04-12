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
            XCTAssertTrue(metadata.hasAttachedArtworkStream)
        }
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
