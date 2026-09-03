#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaybackSnapshotTests: XCTestCase {

    private func track(_ path: String) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: path, artist: "", album: "",
                              durationSeconds: 100, artworkSource: .none),
            metadata: ConversionMetadata(title: path)
        )
    }

    private func paths(_ n: Int) -> [String] { (0..<n).map { "/m/\($0).flac" } }

    // MARK: Building

    func testTheSnapshotStartsAtTheLoadedTrack() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(5), currentIndex: 2, positionSeconds: 12.5, sourceKey: "all"))
        XCTAssertEqual(snapshot.paths, ["/m/2.flac", "/m/3.flac", "/m/4.flac"])
        XCTAssertEqual(snapshot.currentIndex, 0)
        XCTAssertEqual(snapshot.positionSeconds, 12.5)
        XCTAssertEqual(snapshot.sourceKey, "all")
    }

    func testTheSnapshotIsCappedAfterTheLoadedTrack() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(2000), currentIndex: 10, positionSeconds: 0, sourceKey: "all"))
        XCTAssertEqual(snapshot.paths.count, PlaybackSnapshot.maxUpNext + 1)
        XCTAssertEqual(snapshot.paths.first, "/m/10.flac")
    }

    func testNothingToSnapshot() {
        XCTAssertNil(PlaybackSnapshot(paths: [], currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(PlaybackSnapshot(paths: paths(3), currentIndex: 3, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(PlaybackSnapshot(paths: paths(3), currentIndex: -1, positionSeconds: 0, sourceKey: "all"))
    }

    func testANegativePositionIsClampedToZero() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(1), currentIndex: 0, positionSeconds: -3, sourceKey: "all"))
        XCTAssertEqual(snapshot.positionSeconds, 0)
    }

    // MARK: Resolving

    private func known(_ set: Set<String>) -> (String) -> LoadedTrack? {
        { set.contains($0) ? self.track($0) : nil }
    }

    func testResolveKeepsWhatTheLibraryKnows() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 30, sourceKey: "crate:Jazz"))
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(Set(paths(4))), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), paths(4))
        XCTAssertEqual(resolved.currentIndex, 0)
        XCTAssertEqual(resolved.positionSeconds, 30)
        XCTAssertEqual(resolved.sourceKey, "crate:Jazz")
    }

    func testForgottenPathsAfterTheLoadedTrackAreDroppedWithoutMovingIt() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(["/m/0.flac", "/m/2.flac"]), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), ["/m/0.flac", "/m/2.flac"])
        XCTAssertEqual(resolved.currentIndex, 0)
    }

    func testForgottenPathsBeforeTheLoadedTrackShiftTheIndex() throws {
        // A hand-built snapshot with history before the loaded track; the
        // init never produces one, but a decoded file could.
        var snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        snapshot.currentIndex = 2
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(["/m/0.flac", "/m/2.flac", "/m/3.flac"]), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), ["/m/0.flac", "/m/2.flac", "/m/3.flac"])
        XCTAssertEqual(resolved.currentIndex, 1, "the loaded track is now second")
    }

    func testAForgottenLoadedTrackMeansNothingToRestore() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(snapshot.resolve(track: known(["/m/1.flac", "/m/2.flac"]), fileExists: { _ in true }))
    }

    func testAMissingLoadedFileMeansNothingToRestoreButALaterOneStays() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(snapshot.resolve(track: known(Set(paths(3))), fileExists: { $0 != "/m/0.flac" }),
                     "no file on disk for the loaded track: do not put up a track that cannot play")
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(Set(paths(3))), fileExists: { $0 != "/m/2.flac" }))
        XCTAssertEqual(resolved.tracks.count, 3, "a later file being offline is playback's problem, not the snapshot's")
    }

    func testAnOutOfRangeIndexResolvesToNothing() throws {
        var snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(2), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        snapshot.currentIndex = 5
        XCTAssertNil(snapshot.resolve(track: known(Set(paths(2))), fileExists: { _ in true }))
    }

    // MARK: Coding

    func testRoundTrip() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 1, positionSeconds: 7, sourceKey: "prep"))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSnapshot.self, from: data), snapshot)
    }
}
#endif
