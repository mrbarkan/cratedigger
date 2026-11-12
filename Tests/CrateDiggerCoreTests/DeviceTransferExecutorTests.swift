#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Running a device file plan against a temp-dir "device": copies first,
/// then the deletions their albums earned. Every write goes to a hidden
/// partial file and is renamed into place only once complete, with the file
/// system checked right before the rename.
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

    // MARK: - Order

    func testDeletesAfterCopies() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let plan = plan([new], deletions: [kindOfBlue: [old]])

        var oldExistedDuringCopy = false
        let outcome = executor.run(plan, copy: { copy, url in
            oldExistedDuringCopy = FileManager.default.fileExists(atPath: old.path)
            try self.copyFile(copy, url)
        })

        XCTAssertTrue(oldExistedDuringCopy, "the old file must still be there while the new one is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.destinationURL.path))
        XCTAssertEqual(outcome.written, [new])
        XCTAssertEqual(outcome.deleted, [old])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(outcome.removedPaths, [old.path])
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"],
                       "the new file only: old one gone, no partial left")
    }

    func testFailedCopyKeepsItsAlbumsOldFiles() throws {
        let oldBlue = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let oldBrew = try file(device, "Miles Davis/Bitches Brew/01 Pharaoh's Dance.mp3", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let brew = try copyItem("01 Pharaoh's Dance.flac",
                                to: "Miles Davis/Bitches Brew/01 Pharaoh's Dance.flac", album: bitchesBrew)
        let plan = plan([blue, brew], deletions: [kindOfBlue: [oldBlue], bitchesBrew: [oldBrew]])

        let outcome = executor.run(plan, copy: { copy, url in
            if copy.album == self.bitchesBrew { throw self.failure("Disk full") }
            try self.copyFile(copy, url)
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

    // MARK: - Partial files

    func testCopiesAreWrittenToAHiddenPartialFirst() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        var writtenTo: URL?

        _ = executor.run(plan([new]), copy: { copy, url in
            writtenTo = url
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.destinationURL.path),
                           "nothing under the final name while writing")
            try self.copyFile(copy, url)
        })

        XCTAssertEqual(writtenTo?.lastPathComponent, ".01 So What.flac.cdpart")
        XCTAssertEqual(writtenTo?.deletingLastPathComponent(), new.destinationURL.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "new")
    }

    func testFailedCopyLeavesNothingAtTheDestination() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let folder = new.destinationURL.deletingLastPathComponent()

        let outcome = executor.run(plan([new]), copy: { _, url in
            try "half a fi".write(to: url, atomically: false, encoding: .utf8)
            throw self.failure("Device unplugged")
        })

        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.destinationURL.path))
        XCTAssertEqual(leftovers(in: folder), [], "the partial is removed too")
    }

    func testFailedOverwriteKeepsTheOldFile() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old art")
        let swap = try copyItem("01 So What.mp3", to: "Miles Davis/Kind of Blue/01 So What.mp3",
                                album: kindOfBlue, overwrites: true, contents: "new art")

        let outcome = executor.run(plan([swap]), copy: { _, url in
            try "new a".write(to: url, atomically: false, encoding: .utf8)
            throw self.failure("Device unplugged")
        })

        XCTAssertEqual(outcome.failed.map(\.copy), [swap])
        XCTAssertEqual(try String(contentsOf: swap.destinationURL, encoding: .utf8), "old art")
        XCTAssertEqual(leftovers(in: swap.destinationURL.deletingLastPathComponent()), ["01 So What.mp3"])
    }

    func testOverwriteReplaces() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old art")
        let swap = try copyItem("01 So What.mp3", to: "Miles Davis/Kind of Blue/01 So What.mp3",
                                album: kindOfBlue, overwrites: true, contents: "new art")

        let outcome = executor.run(plan([swap]), copy: copyFile)

        XCTAssertEqual(outcome.written, [swap])
        XCTAssertEqual(try String(contentsOf: swap.destinationURL, encoding: .utf8), "new art")
        XCTAssertEqual(leftovers(in: swap.destinationURL.deletingLastPathComponent()), ["01 So What.mp3"])
    }

    func testAppearedFileFailsThatItemOnly() throws {
        let taken = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let free = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.flac", album: kindOfBlue)
        // Someone else's file landed at the planned name after the review.
        try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "theirs")

        let outcome = executor.run(plan([taken, free]), copy: copyFile)

        XCTAssertEqual(outcome.failed.map(\.copy), [taken])
        XCTAssertEqual(outcome.failed.first?.reason, DeviceTransferExecutor.appearedReason)
        XCTAssertEqual(try String(contentsOf: taken.destinationURL, encoding: .utf8), "theirs", "never overwritten")
        XCTAssertEqual(outcome.written, [free])
    }

    func testAppearedFileIsCheckedBeforeTheRename() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)

        // The file lands while the copy is being written, after the first check.
        let outcome = executor.run(plan([new]), copy: { copy, url in
            try self.copyFile(copy, url)
            try "theirs".write(to: copy.destinationURL, atomically: true, encoding: .utf8)
        })

        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertEqual(outcome.failed.first?.reason, DeviceTransferExecutor.appearedReason)
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "theirs")
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"])
    }

    func testLeftoverPartialFromACrashIsReplaced() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let stale = DeviceTransferExecutor.partialURL(for: new.destinationURL, keepingExtension: false)
        try file(device, "Miles Davis/Kind of Blue/\(stale.lastPathComponent)", "stale half")

        let outcome = executor.run(plan([new]), copy: copyFile)

        XCTAssertEqual(outcome.written, [new])
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "new")
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"])
    }

    // MARK: - The convert side's finish step

    func testFinishMovesAConvertedPartialIntoPlaceAndRefusesAnAppearedFile() throws {
        let destination = device.appendingPathComponent("Miles Davis/Kind of Blue/01 So What.mp3")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = try executor.clearPartial(for: destination, keepingExtension: true)
        XCTAssertEqual(partial.lastPathComponent, ".cdpart.01 So What.mp3", "ffmpeg still sees .mp3")
        try "encoded".write(to: partial, atomically: true, encoding: .utf8)

        try executor.finish(partial, onto: destination, overwrites: false)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        // A second run of the same name while a file now sits there.
        let again = try executor.clearPartial(for: destination, keepingExtension: true)
        try "encoded again".write(to: again, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try executor.finish(again, onto: destination, overwrites: false)) { error in
            XCTAssertEqual(error.localizedDescription, DeviceTransferExecutor.appearedReason)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))

        // Cleared for overwriting, the same finish replaces it.
        let replace = try executor.clearPartial(for: destination, keepingExtension: true)
        try "re-encoded".write(to: replace, atomically: true, encoding: .utf8)
        try executor.finish(replace, onto: destination, overwrites: true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "re-encoded")
    }

    // MARK: - Progress, cancel, unplanned

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

    func testCancelDuringTheLastCopyRunsNoDeletions() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        var cancelled = false

        let outcome = executor.run(
            plan([new], deletions: [kindOfBlue: [old]]),
            copy: { copy, url in
                try self.copyFile(copy, url)
                cancelled = true   // the user presses Cancel while this copy runs
            },
            isCancelled: { cancelled }
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.written, [new], "the copy that finished stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "no deletion after a cancel")
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertEqual(outcome.deletionsSkipped, [kindOfBlue])
        XCTAssertTrue(outcome.lines.contains { $0.contains(DeviceTransferExecutor.cancelledDeletionReason) })
    }

    func testCancelBetweenAlbumsStopsTheRemainingDeletions() throws {
        let oldBlue = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let oldBrew = try file(device, "Miles Davis/Bitches Brew/01 Pharaoh's Dance.mp3", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let brew = try copyItem("01 Pharaoh's Dance.flac",
                                to: "Miles Davis/Bitches Brew/01 Pharaoh's Dance.flac", album: bitchesBrew)
        let plan = plan([blue, brew], deletions: [kindOfBlue: [oldBlue], bitchesBrew: [oldBrew]])

        var outcome = executor.runCopies(plan, copy: copyFile)
        var checks = 0
        executor.runDeletions(plan, after: &outcome, isCancelled: {
            checks += 1
            return checks > 1   // cancelled once the first album's files are gone
        })

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBlue.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBrew.path))
        XCTAssertEqual(outcome.deletionsSkipped, [bitchesBrew])
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

    private func copyFile(_ copy: DeviceTransferFilePlan.Copy, _ url: URL) throws {
        try FileManager.default.copyItem(at: copy.source.track.fileURL, to: url)
    }

    private func failure(_ reason: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    /// Every entry in `folder`, hidden ones included, sorted.
    private func leftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
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
