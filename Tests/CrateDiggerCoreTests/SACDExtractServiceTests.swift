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
#endif
