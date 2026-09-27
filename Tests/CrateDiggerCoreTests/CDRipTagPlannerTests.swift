#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// What a disc's tracks rip with: the picked release, the user's staged edits
/// on top, and which files a finished rip should hand to the Prep Crate.
final class CDRipTagPlannerTests: XCTestCase {

    private let volume = URL(fileURLWithPath: "/Volumes/Audio CD")

    private func disc(tracks count: Int, name: String = "Audio CD") -> AudioCDInfo {
        AudioCDInfo(
            volumeURL: volume,
            name: name,
            tracks: (1...count).map {
                CDTrack(fileURL: volume.appendingPathComponent("\($0) Audio Track.aiff"),
                        title: "\($0) Audio Track", trackNumber: $0)
            }
        )
    }

    private func release(discs: [Int: Int], totalDiscs: Int? = nil) -> ReleaseCandidate {
        let tracks = discs.keys.sorted().flatMap { discNumber in
            (1...discs[discNumber]!).map {
                ReleaseTrack(position: $0, discNumber: discNumber,
                             title: "D\(discNumber) T\($0)", durationSeconds: 100)
            }
        }
        return ReleaseCandidate(source: .musicBrainz, providerID: "mbid",
                                title: "The Box", artist: "The Band",
                                year: 1971, genre: "Rock",
                                totalTracks: tracks.count, totalDiscs: totalDiscs, tracks: tracks)
    }

    // MARK: - Without a release

    func testUnidentifiedDiscKeepsWhatMacOSGave() {
        let tracks = CDRipTagPlanner.tracks(for: disc(tracks: 2, name: "MY DISC"), release: nil, cover: nil)
        XCTAssertEqual(tracks.map(\.metadata.title), ["1 Audio Track", "2 Audio Track"])
        XCTAssertEqual(tracks.first?.metadata.album, "MY DISC")
        XCTAssertEqual(tracks.first?.metadata.artist, "Audio CD")
        XCTAssertEqual(tracks.first?.metadata.trackTotal, 2)
        XCTAssertNil(tracks.first?.metadata.discNumber)
    }

    // MARK: - With a release

    func testReleaseTagsEveryTrack() {
        let tracks = CDRipTagPlanner.tracks(for: disc(tracks: 2), release: release(discs: [1: 2]), cover: nil)
        let first = tracks[0].metadata
        XCTAssertEqual(first.title, "D1 T1")
        XCTAssertEqual(first.artist, "The Band")
        XCTAssertEqual(first.albumArtist, "The Band")
        XCTAssertEqual(first.album, "The Box")
        XCTAssertEqual(first.year, 1971)
        XCTAssertEqual(first.genre, "Rock")
        XCTAssertEqual(tracks[0].track.durationSeconds, 100)
        // A single-disc album isn't stamped "disc 1 of 1".
        XCTAssertNil(first.discNumber)
        XCTAssertNil(first.discTotal)
    }

    /// A box set's disc ID resolves to the whole set: the disc in the drive is
    /// the one with this many tracks, and its rip must say which disc it is, or
    /// every disc of the set lands in one folder as tracks 1…n of "disc 1".
    func testBoxSetDiscTakesItsOwnTitlesAndDiscNumber() {
        let box = release(discs: [1: 4, 2: 3, 3: 5], totalDiscs: 3)
        XCTAssertEqual(CDRipTagPlanner.discNumber(in: box, trackCount: 5), 3)

        let tracks = CDRipTagPlanner.tracks(for: disc(tracks: 5), release: box, cover: nil)
        XCTAssertEqual(tracks.map(\.metadata.title), ["D3 T1", "D3 T2", "D3 T3", "D3 T4", "D3 T5"])
        XCTAssertEqual(tracks[0].metadata.discNumber, 3)
        XCTAssertEqual(tracks[0].metadata.discTotal, 3)
        XCTAssertEqual(tracks[0].track.discNumber, 3)
        // Track total is this disc's, not the whole set's.
        XCTAssertEqual(tracks[0].metadata.trackTotal, 5)
    }

    func testDiscTotalFallsBackToTheTrackListWhenTheReleaseOmitsIt() {
        let tracks = CDRipTagPlanner.tracks(for: disc(tracks: 3), release: release(discs: [1: 4, 2: 3]), cover: nil)
        XCTAssertEqual(tracks[0].metadata.discNumber, 2)
        XCTAssertEqual(tracks[0].metadata.discTotal, 2)
    }

    // MARK: - Staged edits

    /// Editing a track on the CD can't write the disc; the edit is staged and
    /// the rip carries it instead of the release's value.
    func testStagedEditOverridesTheRelease() {
        let cd = disc(tracks: 2)
        var edited = CDRipTagPlanner.tracks(for: cd, release: release(discs: [1: 2]), cover: nil)[1].metadata
        edited.title = "My Title"
        edited.genre = "Prog"

        let tracks = CDRipTagPlanner.tracks(
            for: cd, release: release(discs: [1: 2]), cover: nil,
            stagedEdits: [cd.tracks[1].fileURL.path: edited]
        )
        XCTAssertEqual(tracks[0].metadata.title, "D1 T1")
        XCTAssertEqual(tracks[1].metadata.title, "My Title")
        XCTAssertEqual(tracks[1].metadata.genre, "Prog")
        // The browser shows the edit too, not just the rip.
        XCTAssertEqual(tracks[1].track.title, "My Title")
    }

    /// The cover arrives after the release is picked; an edit made in between
    /// must not strip it from that track.
    func testCoverThatArrivesAfterAnEditStillReachesTheTrack() {
        let cd = disc(tracks: 1)
        var edited = CDRipTagPlanner.tracks(for: cd, release: nil, cover: nil)[0].metadata
        edited.title = "Edited"
        let cover = ArtworkAsset(source: .remote, hash: "abc",
                                 dimensions: ArtworkDimensions(width: 1, height: 1), data: Data([1, 2, 3]))

        let tracks = CDRipTagPlanner.tracks(
            for: cd, release: nil, cover: cover,
            stagedEdits: [cd.tracks[0].fileURL.path: edited]
        )
        XCTAssertEqual(tracks[0].metadata.title, "Edited")
        XCTAssertEqual(tracks[0].metadata.artwork, cover)
    }

    /// Staging an edit rebuilds the disc's tracks; the edited track must keep
    /// its identity or the browser drops the selection back to track 1.
    func testTrackIdentitySurvivesARebuild() {
        let cd = disc(tracks: 3)
        let before = CDRipTagPlanner.tracks(for: cd, release: nil, cover: nil)
        var edited = before[2].metadata
        edited.title = "Edited"
        let after = CDRipTagPlanner.tracks(for: cd, release: release(discs: [1: 3]), cover: nil,
                                           stagedEdits: [cd.tracks[2].fileURL.path: edited])
        XCTAssertEqual(before.map(\.track.id), after.map(\.track.id))
        XCTAssertEqual(Set(after.map(\.track.id)).count, 3)
    }

    // MARK: - What the rip imports

    /// The rip imports what it wrote, not the whole destination: scanning the
    /// output root staged every album ever converted there.
    func testImportFoldersAreTheAlbumFoldersTheRipWrote() {
        let written = [
            URL(fileURLWithPath: "/Out/The Band/1971 - The Box/03-01 A.flac"),
            URL(fileURLWithPath: "/Out/The Band/1971 - The Box/03-02 B.flac"),
            URL(fileURLWithPath: "/Out/The Band/1971 - The Box/03-03 C.flac"),
        ]
        XCTAssertEqual(CDRipTagPlanner.importFolders(forWritten: written).map(\.path),
                       ["/Out/The Band/1971 - The Box"])
    }

    func testImportFoldersKeepFirstSeenOrderAcrossFolders() {
        let written = [
            URL(fileURLWithPath: "/Out/B/x.flac"),
            URL(fileURLWithPath: "/Out/A/y.flac"),
            URL(fileURLWithPath: "/Out/B/z.flac"),
        ]
        XCTAssertEqual(CDRipTagPlanner.importFolders(forWritten: written).map(\.path), ["/Out/B", "/Out/A"])
    }

    func testNothingWrittenImportsNothing() {
        XCTAssertEqual(CDRipTagPlanner.importFolders(forWritten: []), [])
    }
}
#endif
