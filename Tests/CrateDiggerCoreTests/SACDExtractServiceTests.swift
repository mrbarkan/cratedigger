#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class SACDISOInspectorTests: XCTestCase {
    /// Writes `magic` at the SACD Master TOC offset (sector 510 × 2048 bytes).
    private func makeISO(magic: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).iso")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 510 * 2048)
        try handle.write(contentsOf: Data(magic.utf8))
        try handle.close()
        return url
    }

    func testRecognizesSACDMagic() throws {
        let iso = try makeISO(magic: "SACDMTOC")
        defer { try? FileManager.default.removeItem(at: iso) }
        XCTAssertTrue(SACDISOInspector.isSACDISO(iso))
    }

    func testRejectsOrdinaryISOAndShortFile() throws {
        let plain = try makeISO(magic: "CD001___")
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(plain))

        let tiny = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).iso")
        try Data("hi".utf8).write(to: tiny)
        defer { try? FileManager.default.removeItem(at: tiny) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(tiny))
    }
}

final class SACDMetadataParserTests: XCTestCase {
    /// Trimmed real `sacd_extract -P` output (Wish You Were Here SACD).
    private let fixture = """
    sacd_extract client 0.3.9.3

    Disc Information:
    \tVersion:  1.20
    \tCreation date: 2011-03-05
    \tTitle: Wish You Were Here
    \tArtist: Pink Floyd

    Album Information:
    \tAlbum Catalog Number: B0000254SA
    \tTitle: Wish You Were Here
    \tArtist: Pink Floyd

    Area count: 2
    \tArea Information [0]:

    \tVersion:  1.20
    \tTrack Count: 2
    \tSpeaker config: 2 Channel
    \tTrack list [0]:
    \t\tTitle[0]: Shine On You Crazy Diamond (Parts I - V)
    \t\tPerformer[0]: Pink Floyd
    \t\tDuration: 13:30:50 [mins:secs:frames]

    \t\tTitle[1]: Welcome To The Machine
    \t\tPerformer[1]: Pink Floyd
    \t\tDuration: 07:25:29 [mins:secs:frames]

    \tArea Information [1]:

    \tTrack Count: 2
    \tSpeaker config: 6 Channel
    \tTrack list [1]:
    \t\tTitle[0]: Multichannel Ghost
    \t\tPerformer[0]: Pink Floyd
    \t\tDuration: 13:30:50 [mins:secs:frames]
    """

    func testParsesAlbumStereoTracksAndYear() throws {
        let disc = try XCTUnwrap(SACDMetadataParser.parse(fixture))
        XCTAssertEqual(disc.albumTitle, "Wish You Were Here")
        XCTAssertEqual(disc.albumArtist, "Pink Floyd")
        XCTAssertEqual(disc.year, 2011)
        // Only the 2-channel area's tracks — the 6-channel ghost is excluded.
        XCTAssertEqual(disc.stereoTracks.count, 2)
        XCTAssertEqual(disc.stereoTracks[0].number, 1)
        XCTAssertEqual(disc.stereoTracks[0].title, "Shine On You Crazy Diamond (Parts I - V)")
        // 13 min 30 sec 50 frames @ 75 fps
        XCTAssertEqual(disc.stereoTracks[0].durationSeconds, 13 * 60 + 30 + 50.0 / 75.0, accuracy: 0.001)
        XCTAssertEqual(disc.stereoTracks[1].number, 2)
        XCTAssertEqual(disc.stereoTracks[1].title, "Welcome To The Machine")
    }

    func testNoStereoAreaReturnsNil() {
        XCTAssertNil(SACDMetadataParser.parse("Disc Information:\n\tTitle: X\n"))
    }
}

/// CommandRunning fake that records invocations and simulates sacd_extract's
/// on-disk behavior (writes "<Album>/Stereo/NN - Title.dsf" under the -y dir).
private final class FakeSACDRunner: CommandRunning {
    var invocations: [[String]] = []
    var failOnCall: Int?
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        invocations.append(arguments)
        if let failOn = failOnCall, invocations.count == failOn {
            return CommandOutput(terminationStatus: 1, standardOutput: "", standardError: "bad sector")
        }
        if let tIndex = arguments.firstIndex(of: "-t"), let yIndex = arguments.firstIndex(of: "-y") {
            let track = arguments[tIndex + 1]
            let outDir = URL(fileURLWithPath: arguments[yIndex + 1])
            let stereo = outDir.appendingPathComponent("Album/Stereo", isDirectory: true)
            try FileManager.default.createDirectory(at: stereo, withIntermediateDirectories: true)
            try Data("dsf".utf8).write(to: stereo.appendingPathComponent("0\(track) - T\(track).dsf"))
        }
        return CommandOutput(terminationStatus: 0, standardOutput: "", standardError: "")
    }
}

final class SACDExtractServiceTests: XCTestCase {
    private let tool = URL(fileURLWithPath: "/usr/local/bin/sacd_extract")

    func testArgumentBuilders() {
        XCTAssertEqual(SACDExtractService.printArguments(iso: URL(fileURLWithPath: "/a/d.iso")),
                       ["-P", "-i", "/a/d.iso"])
        XCTAssertEqual(SACDExtractService.extractArguments(iso: URL(fileURLWithPath: "/a/d.iso"),
                                                           trackNumber: 4,
                                                           outputDir: URL(fileURLWithPath: "/out")),
                       ["-s", "-2", "-c", "-t", "4", "-i", "/a/d.iso", "-y", "/out"])
    }

    func testExtractRunsPerTrackMovesFilesAndReportsProgress() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sacd-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let runner = FakeSACDRunner()
        let service = SACDExtractService(toolURL: tool, commandRunner: runner)

        let exp = expectation(description: "extract")
        var progress: [(Int, Int)] = []
        var extracted: [URL] = []
        service.extractStereoTracks(iso: URL(fileURLWithPath: "/a/d.iso"),
                                    trackNumbers: [1, 2],
                                    to: dest,
                                    onTrackDone: { progress.append(($0, $1)) }) { result in
            if case .success(let urls) = result { extracted = urls }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(progress.map { $0.0 }, [1, 2])
        XCTAssertEqual(progress.map { $0.1 }, [2, 2])
        XCTAssertEqual(extracted.count, 2)
        // Files are flattened out of "<Album>/Stereo/" into the destination.
        XCTAssertEqual(Set(extracted.map { $0.deletingLastPathComponent().path }), [dest.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("01 - T1.dsf").path))
    }

    func testExtractFailureSurfacesStderr() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sacd-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let runner = FakeSACDRunner()
        runner.failOnCall = 1
        let service = SACDExtractService(toolURL: tool, commandRunner: runner)

        let exp = expectation(description: "extract")
        var failure: Error?
        service.extractStereoTracks(iso: URL(fileURLWithPath: "/a/d.iso"), trackNumbers: [1],
                                    to: dest, onTrackDone: { _, _ in }) { result in
            if case .failure(let error) = result { failure = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        guard case .some(SACDExtractError.toolFailed(let message)) = failure else {
            return XCTFail("expected toolFailed, got \(String(describing: failure))")
        }
        XCTAssertTrue(message.contains("bad sector"))
    }
}
#endif
