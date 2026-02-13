#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class MetadataProbeServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var fakeFFprobeURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateDiggerMetadataProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        fakeFFprobeURL = temporaryDirectory.appendingPathComponent("ffprobe")
        let stub = "#!/bin/sh\necho ffprobe stub\n"
        guard let stubData = stub.data(using: .utf8) else {
            throw NSError(domain: "MetadataProbeServiceTests", code: 11)
        }
        try stubData.write(to: fakeFFprobeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFprobeURL.path)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

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

    func testProbeThrowsOnCommandFailure() throws {
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

private struct FixedOutputCommandRunner: CommandRunning {
    let output: CommandOutput

    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        output
    }
}
#endif
