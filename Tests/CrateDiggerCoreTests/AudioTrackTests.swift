import XCTest
@testable import CrateDiggerCore

final class AudioTrackTests: XCTestCase {
    func testWithIDChangesOnlyIdentity() {
        let original = AudioTrack(
            fileURL: URL(fileURLWithPath: "/Music/sideA.aiff"),
            title: "Side A", artist: "Lorde", album: "Solar Power",
            durationSeconds: 2570, formatName: "AIFF", bitrateKbps: 1411,
            sampleRateHz: 44100, year: 2021, trackNumber: 1, trackTotal: 2,
            discNumber: 1, discTotal: 1, artworkSource: .embedded, artworkHash: "abc"
        )
        let newID = UUID()
        let copy = original.withID(newID)

        XCTAssertEqual(copy.id, newID)
        XCTAssertNotEqual(copy.id, original.id)
        // Everything else is identical.
        XCTAssertEqual(copy.withID(original.id), original)
    }
}
