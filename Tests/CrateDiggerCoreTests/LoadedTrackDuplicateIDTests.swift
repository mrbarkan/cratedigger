#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// A crate that ends up holding two entries with the same track UUID (one file
/// imported twice to different paths) breaks SwiftUI ForEach identity — the
/// browser renders blank ghost rows. `healingDuplicateIDs` repairs the crate
/// contents at load time.
final class LoadedTrackDuplicateIDTests: XCTestCase {

    private func mk(id: UUID = UUID(), path: String) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(id: id, fileURL: URL(fileURLWithPath: path),
                                      title: "Yi", artist: "Bon Iver", album: "i,i"),
                    metadata: ConversionMetadata(),
                    recordMarkers: [RecordMarker(startSeconds: 0, endSeconds: 10, title: "M")])
    }

    func testUniqueIDsPassThroughUntouched() {
        let tracks = [mk(path: "/a/one.flac"), mk(path: "/a/two.flac")]
        XCTAssertEqual(LoadedTrack.healingDuplicateIDs(tracks), tracks)
    }

    func testSameIDDifferentPathGetsFreshID() {
        let sharedID = UUID()
        let original = mk(id: sharedID, path: "/lib/01 - Yi.flac")
        let copy = mk(id: sharedID, path: "/lib/01 - Yi (1).flac")

        let healed = LoadedTrack.healingDuplicateIDs([original, copy])

        XCTAssertEqual(healed.count, 2)
        XCTAssertEqual(healed[0], original, "first occurrence keeps its identity")
        XCTAssertNotEqual(healed[1].track.id, sharedID, "second occurrence must get a fresh id")
        // Everything except the id survives the heal.
        XCTAssertEqual(healed[1].track.fileURL, copy.track.fileURL)
        XCTAssertEqual(healed[1].track.title, copy.track.title)
        XCTAssertEqual(healed[1].metadata, copy.metadata)
        XCTAssertEqual(healed[1].recordMarkers, copy.recordMarkers)
    }

    /// The index build heals on entry, so every browsable source (crates,
    /// merged All Records, prep crate, devices) gets unique row identity.
    func testIndexBuildHealsDuplicateIDs() {
        let sharedID = UUID()
        let index = LibraryIndex.build(from: [mk(id: sharedID, path: "/lib/01 - Yi.flac"),
                                              mk(id: sharedID, path: "/lib/01 - Yi (1).flac")])
        XCTAssertEqual(index.allTracks.count, 2)
        XCTAssertEqual(Set(index.allTracks.map { $0.track.id }).count, 2)
    }

    func testSameIDSamePathDropsTheRepeatEntry() {
        let sharedID = UUID()
        let entry = mk(id: sharedID, path: "/lib/01 - Yi.flac")
        let healed = LoadedTrack.healingDuplicateIDs([entry, entry])
        XCTAssertEqual(healed, [entry], "a literal double entry is one track, not two")
    }
}
#endif
