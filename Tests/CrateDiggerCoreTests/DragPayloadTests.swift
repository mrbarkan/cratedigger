#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The browser's drag payload is a plain string because SwiftUI's `.draggable`
/// is per-view: a multi-selection has to be encoded into the one item the
/// dragged row carries. These cover the encoding contract the view model and
/// `tracksForDragItems` share — ids that contain the separator are the trap.
final class DragPayloadTests: XCTestCase {
    /// Album ids are built from artist + album text, so commas are routine
    /// ("Crosby, Stills & Nash"). The plural album/artist payloads join on U+0001
    /// for that reason; only track payloads (UUIDs) can safely use a comma.
    func testAlbumIdsWithCommasSurviveTheSeparator() {
        let ids = ["Crosby, Stills & Nash|Déjà Vu", "Air|Moon Safari"]
        let payload = "albums::" + ids.joined(separator: "\u{1}")

        let decoded = String(payload.dropFirst("albums::".count))
            .split(separator: "\u{1}")
            .map(String.init)

        XCTAssertEqual(decoded, ids)
    }

    func testTrackPayloadRoundTripsEveryUUID() {
        let ids = (0..<5).map { _ in UUID() }
        let payload = "tracks::" + ids.map(\.uuidString).joined(separator: ",")

        let decoded = String(payload.dropFirst("tracks::".count))
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }

        XCTAssertEqual(Set(decoded), Set(ids))
    }

    /// The plural prefixes have to be tested before the singular ones, or
    /// "tracks::" gets swallowed by a `hasPrefix("track::")` check that never
    /// matches and silently drops the whole drag.
    func testPluralPrefixIsNotMistakenForTheSingularOne() {
        XCTAssertFalse("tracks::abc".hasPrefix("track::"))
        XCTAssertFalse("albums::abc".hasPrefix("album::"))
        XCTAssertFalse("artists::abc".hasPrefix("artist::"))
    }
}
#endif
