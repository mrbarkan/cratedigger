#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The one line every device transfer ends with: what was copied, what was
/// already there and what the review decided, in words the user reads.
final class DeviceTransferSummaryTests: XCTestCase {
    func testAllCounts() {
        let line = DeviceTransferSummary.statusLine(
            copied: 120, alreadyThere: 14, gapAlbums: 6, replaced: 3, keptBoth: 2, leftAlone: 4, failed: 5
        )
        XCTAssertEqual(
            line,
            "120 files copied · 14 already there · 6 albums finished · 3 albums replaced"
                + " · 2 albums kept beside the old copy · 4 albums left alone · 5 failed"
        )
    }

    func testOmitsZeroParts() {
        XCTAssertEqual(
            DeviceTransferSummary.statusLine(
                copied: 0, alreadyThere: 14, gapAlbums: 0, replaced: 0, keptBoth: 0, leftAlone: 0, failed: 0
            ),
            "14 already there"
        )
        XCTAssertEqual(
            DeviceTransferSummary.statusLine(
                copied: 3, alreadyThere: 0, gapAlbums: 0, replaced: 0, keptBoth: 0, leftAlone: 2, failed: 0
            ),
            "3 files copied · 2 albums left alone"
        )
        XCTAssertEqual(
            DeviceTransferSummary.statusLine(
                copied: 0, alreadyThere: 0, gapAlbums: 0, replaced: 0, keptBoth: 0, leftAlone: 0, failed: 0
            ),
            "Nothing to send"
        )
    }

    func testSingulars() {
        XCTAssertEqual(
            DeviceTransferSummary.statusLine(
                copied: 1, alreadyThere: 1, gapAlbums: 1, replaced: 1, keptBoth: 1, leftAlone: 1, failed: 1
            ),
            "1 file copied · 1 already there · 1 album finished · 1 album replaced"
                + " · 1 album kept beside the old copy · 1 album left alone · 1 failed"
        )
    }

    // MARK: - From a plan and what ran

    func testAlbumsWithAFailedCopyAreNotCountedAsDone() {
        let replaced = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
        let broken = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")
        let filled = DeviceAlbumIdentity(artist: "Talk Talk", album: "Spirit of Eden")
        let ok1 = copy("a", album: replaced, kind: .replacement)
        let bad = copy("b", album: broken, kind: .replacement)
        let gap = copy("c", album: filled, kind: .gap)
        let plan = DeviceTransferFilePlan(
            copies: [ok1, bad, gap],
            deletionsByAlbum: [:],
            coverFolders: [:],
            skippedPresent: 9,
            leftAlone: 1,
            replacedAlbums: 2,
            keptBothAlbums: 0,
            gapAlbums: 1,
            unplanned: [track("lost")]
        )
        var outcome = DeviceTransferExecutor.Outcome()
        outcome.written = [ok1, gap]
        outcome.failed = [.init(copy: bad, reason: "Disk full")]

        XCTAssertEqual(
            DeviceTransferSummary.statusLine(for: plan, outcome: outcome),
            "2 files copied · 9 already there · 1 album finished · 1 album replaced · 1 album left alone · 2 failed"
        )
        XCTAssertEqual(DeviceTransferSummary.failedCount(for: plan, outcome: outcome), 2)
    }

    func testAReplaceWhoseOldFilesACancelKeptIsNotCountedAsReplaced() {
        let album = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
        let written = copy("a", album: album, kind: .replacement)
        let plan = DeviceTransferFilePlan(
            copies: [written], deletionsByAlbum: [album: [URL(fileURLWithPath: "/V/Music/a.mp3")]],
            coverFolders: [:], skippedPresent: 0, leftAlone: 0, replacedAlbums: 1, keptBothAlbums: 0, gapAlbums: 0
        )
        var outcome = DeviceTransferExecutor.Outcome()
        outcome.written = [written]
        outcome.deletionsSkipped = [album]

        XCTAssertEqual(DeviceTransferSummary.statusLine(for: plan, outcome: outcome), "1 file copied")
    }

    func testFailedDeletionsCountAsFailed() {
        let plan = DeviceTransferFilePlan(
            copies: [], deletionsByAlbum: [:], coverFolders: [:], skippedPresent: 0,
            leftAlone: 0, replacedAlbums: 0, keptBothAlbums: 0, gapAlbums: 0
        )
        var outcome = DeviceTransferExecutor.Outcome()
        outcome.failedDeletions = [.init(url: URL(fileURLWithPath: "/V/old.mp3"), reason: "Locked")]

        XCTAssertEqual(DeviceTransferSummary.failedCount(for: plan, outcome: outcome), 1)
    }

    // MARK: - Fixtures

    private func track(_ name: String) -> LoadedTrack {
        let audio = AudioTrack(fileURL: URL(fileURLWithPath: "/Src/\(name).flac"), title: name, artist: "A", album: "B")
        return LoadedTrack(track: audio, metadata: ConversionMetadata(title: name, artist: "A", album: "B"))
    }

    private func copy(_ name: String, album: DeviceAlbumIdentity, kind: DeviceTransferFilePlan.Copy.Kind)
        -> DeviceTransferFilePlan.Copy {
        DeviceTransferFilePlan.Copy(
            source: track(name),
            destinationURL: URL(fileURLWithPath: "/V/Music/\(name).flac"),
            overwrites: false,
            kind: kind,
            album: album
        )
    }
}
#endif
