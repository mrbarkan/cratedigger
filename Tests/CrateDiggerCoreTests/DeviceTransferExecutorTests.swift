#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Running a device file plan against a temp-dir "device": copies first,
/// then the deletions their albums earned, with the file system checked
/// right before every write.
final class DeviceTransferExecutorTests: XCTestCase {
    private let executor = DeviceTransferExecutor()
    private var scratch: URL!
    private var source: URL!
    private var device: URL!
    private let kindOfBlue = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
    private let bitchesBrew = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferExecutorTests-\(UUID().uuidString)", isDirectory: true)
        scratch = base.resolvingSymlinksInPath()
        source = scratch.appendingPathComponent("Library", isDirectory: true)
        device = scratch.appendingPathComponent("IPOD/Music", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testDeletesAfterCopies() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let plan = plan([new], deletions: [kindOfBlue: [old]])

        var oldExistedDuringCopy = false
        let outcome = executor.run(plan, copy: { copy in
            oldExistedDuringCopy = FileManager.default.fileExists(atPath: old.path)
            try self.copyFile(copy)
        })

        XCTAssertTrue(oldExistedDuringCopy, "the old file must still be there while the new one is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.destinationURL.path))
        XCTAssertEqual(outcome.written, [new])
        XCTAssertEqual(outcome.deleted, [old])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(outcome.removedPaths, [old.path])
    }

    func testFailedCopyKeepsItsAlbumsOldFiles() throws {
        let oldBlue = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let oldBrew = try file(device, "Miles Davis/Bitches Brew/01 Pharaoh's Dance.mp3", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let brew = try copyItem("01 Pharaoh's Dance.flac",
                                to: "Miles Davis/Bitches Brew/01 Pharaoh's Dance.flac", album: bitchesBrew)
        let plan = plan([blue, brew], deletions: [kindOfBlue: [oldBlue], bitchesBrew: [oldBrew]])

        let outcome = executor.run(plan, copy: { copy in
            if copy.album == self.bitchesBrew {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk full"])
            }
            try self.copyFile(copy)
        })

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBlue.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBrew.path), "a failed write leaves the old file")
        XCTAssertEqual(outcome.failed.map(\.copy), [brew])
        XCTAssertEqual(outcome.failed.first?.reason, "Disk full")
    }

    func testMissingOldFileIsNotAFailure() throws {
        let gone = device.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.mp3")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let plan = plan([new], deletions: [kindOfBlue: [gone]])

        let outcome = executor.run(plan, copy: copyFile)

        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.failedDeletions.isEmpty)
        XCTAssertEqual(outcome.alreadyGone, [gone])
        XCTAssertEqual(outcome.removedPaths, [gone.path], "the catalog still drops a file that is already gone")
    }

    func testAppearedFileFailsThatItemOnly() throws {
        let taken = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let free = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.flac", album: kindOfBlue)
        // Someone else's file landed at the planned name after the review.
        try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "theirs")
        let plan = plan([taken, free])

        let outcome = executor.run(plan, copy: copyFile)

        XCTAssertEqual(outcome.failed.map(\.copy), [taken])
        XCTAssertEqual(outcome.failed.first?.reason, DeviceTransferExecutor.appearedReason)
        XCTAssertEqual(try String(contentsOf: taken.destinationURL, encoding: .utf8), "theirs", "never overwritten")
        XCTAssertEqual(outcome.written, [free])
    }

    func testOverwriteReplaces() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old art")
        let swap = try copyItem("01 So What.mp3", to: "Miles Davis/Kind of Blue/01 So What.mp3",
                                album: kindOfBlue, overwrites: true, contents: "new art")
        let plan = plan([swap])

        let outcome = executor.run(plan, copy: copyFile)

        XCTAssertEqual(outcome.written, [swap])
        XCTAssertEqual(try String(contentsOf: swap.destinationURL, encoding: .utf8), "new art")
    }

    func testCreatesMissingFoldersAndReportsProgress() throws {
        let one = try copyItem("01 A.flac", to: "New Artist/New Album/01 A.flac", album: kindOfBlue)
        let two = try copyItem("02 B.flac", to: "New Artist/New Album/02 B.flac", album: kindOfBlue)
        var steps: [Int] = []

        let outcome = executor.run(plan([one, two]), copy: copyFile, onProgress: { done, total in
            XCTAssertEqual(total, 2)
            steps.append(done)
        })

        XCTAssertEqual(steps, [1, 2])
        XCTAssertEqual(outcome.written, [one, two])
    }

    func testCancelledCopiesFailAndKeepTheirAlbumsOldFiles() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)

        let outcome = executor.run(plan([new], deletions: [kindOfBlue: [old]]), copy: copyFile, isCancelled: { true })

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.destinationURL.path))
    }

    func testUnplannedTracksAreListedAsFailures() throws {
        let lost = track(at: source.appendingPathComponent("lost.flac"))
        let plan = DeviceTransferFilePlan(
            copies: [], deletionsByAlbum: [:], coverFolders: [:], skippedPresent: 0,
            leftAlone: 0, replacedAlbums: 0, keptBothAlbums: 0, gapAlbums: 0, unplanned: [lost]
        )

        let outcome = executor.run(plan, copy: copyFile)

        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("[FAILED] lost.flac") })
    }

    // MARK: - Fixtures

    private func copyFile(_ copy: DeviceTransferFilePlan.Copy) throws {
        try FileManager.default.copyItem(at: copy.source.track.fileURL, to: copy.destinationURL)
    }

    private func plan(
        _ copies: [DeviceTransferFilePlan.Copy],
        deletions: [DeviceAlbumIdentity: [URL]] = [:]
    ) -> DeviceTransferFilePlan {
        DeviceTransferFilePlan(
            copies: copies, deletionsByAlbum: deletions, coverFolders: [:], skippedPresent: 0,
            leftAlone: 0, replacedAlbums: 0, keptBothAlbums: 0, gapAlbums: 0
        )
    }

    private func copyItem(
        _ name: String,
        to relative: String,
        album: DeviceAlbumIdentity,
        overwrites: Bool = false,
        contents: String = "new"
    ) throws -> DeviceTransferFilePlan.Copy {
        let sourceURL = try file(source, name, contents)
        return DeviceTransferFilePlan.Copy(
            source: track(at: sourceURL),
            destinationURL: device.appendingPathComponent(relative),
            overwrites: overwrites,
            kind: overwrites ? .replacement : .new,
            album: album
        )
    }

    @discardableResult
    private func file(_ root: URL, _ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func track(at url: URL) -> LoadedTrack {
        let title = url.deletingPathExtension().lastPathComponent
        let audio = AudioTrack(fileURL: url, title: title, artist: "Miles Davis", album: "Kind of Blue")
        return LoadedTrack(track: audio, metadata: ConversionMetadata(title: title, artist: "Miles Davis", album: "Kind of Blue"))
    }
}
#endif
