import XCTest
@testable import CrateDiggerCore

final class RecordMarkerTests: XCTestCase {

    // MARK: - RecordMarker

    func testDuration() {
        let m = RecordMarker(startSeconds: 60, endSeconds: 240, title: "Echoes")
        XCTAssertEqual(m.durationSeconds, 180, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let m = RecordMarker(startSeconds: 12.5, endSeconds: 200.25, title: "One of These Days")
        let back = try JSONDecoder().decode(RecordMarker.self,
                                            from: try JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.id, 12.5)
    }

    // MARK: - LoadedTrack integration

    private func makeTrack(markers: [RecordMarker]?) -> LoadedTrack {
        let audio = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/sideA.aiff"), title: "Side A")
        return LoadedTrack(track: audio, metadata: ConversionMetadata(), recordMarkers: markers)
    }

    func testLoadedTrackRoundTripWithMarkers() throws {
        let t = makeTrack(markers: [
            RecordMarker(startSeconds: 0, endSeconds: 180, title: "Track 01"),
            RecordMarker(startSeconds: 182, endSeconds: 400, title: "Track 02")
        ])
        let back = try JSONDecoder().decode(LoadedTrack.self,
                                            from: try JSONEncoder().encode(t))
        XCTAssertEqual(back.recordMarkers?.count, 2)
        XCTAssertEqual(back.recordMarkers?[1].title, "Track 02")
    }

    /// A `.cdlib` written before this feature has no `recordMarkers` key — it must
    /// still decode (markers become nil).
    func testDecodesLegacyTrackWithoutMarkersKey() throws {
        let legacy = makeTrack(markers: nil)
        let json = try JSONEncoder().encode(legacy)
        // Optionals are encoded with encodeIfPresent, so the key is absent.
        let text = String(data: json, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("recordMarkers"), "nil markers should omit the key")
        let back = try JSONDecoder().decode(LoadedTrack.self, from: json)
        XCTAssertNil(back.recordMarkers)
        XCTAssertNil(back.recordTrackIndex(at: 10))
    }

    func testRecordTrackIndexAtPlayhead() {
        let t = makeTrack(markers: [
            RecordMarker(startSeconds: 0, endSeconds: 180, title: "A"),
            RecordMarker(startSeconds: 182, endSeconds: 400, title: "B"),
            RecordMarker(startSeconds: 402, endSeconds: 600, title: "C")
        ])
        XCTAssertEqual(t.recordTrackIndex(at: 0), 0)
        XCTAssertEqual(t.recordTrackIndex(at: 100), 0)
        XCTAssertEqual(t.recordTrackIndex(at: 190), 1)
        // In the gap after B, the "current" track stays B until C starts.
        XCTAssertEqual(t.recordTrackIndex(at: 401), 1)
        XCTAssertEqual(t.recordTrackIndex(at: 500), 2)
    }

    func testRecordTrackIndexNilWhenUndivided() {
        XCTAssertNil(makeTrack(markers: nil).recordTrackIndex(at: 5))
        XCTAssertNil(makeTrack(markers: []).recordTrackIndex(at: 5))
    }
}
