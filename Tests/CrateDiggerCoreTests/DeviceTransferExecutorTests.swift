#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Running a device file plan against a temp-dir "device": copies first,
/// then the deletions their albums earned. Every write goes through the
/// write door: a `.cdtmp` beside the destination renamed into place only
/// once complete, the rename itself refusing a file that appeared.
final class DeviceTransferExecutorTests: XCTestCase {
    private var executor: DeviceTransferExecutor!
    private var scratch: URL!
    private var source: URL!
    private var volume: URL!
    private var device: URL!
    private let kindOfBlue = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
    private let bitchesBrew = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferExecutorTests-\(UUID().uuidString)", isDirectory: true)
        scratch = base.resolvingSymlinksInPath()
        source = scratch.appendingPathComponent("Library", isDirectory: true)
        volume = scratch.appendingPathComponent("IPOD", isDirectory: true)
        device = volume.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        executor = DeviceTransferExecutor(door: .onTempFolder(
            volume, musicSubpath: "Music", journalDirectory: scratch.appendingPathComponent("Journal")))
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Order

    func testDeletesAfterCopies() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let plan = plan([new], deletions: [kindOfBlue: [old]])

        var outcome = executor.runCopies(plan, source: copySource)
        let oldExistedAfterCopy = FileManager.default.fileExists(atPath: old.path)
        executor.runDeletions(plan, after: &outcome)

        XCTAssertTrue(oldExistedAfterCopy, "the old file must still be there while the new one is written")
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

        let outcome = executor.run(plan, source: { copy in
            if copy.album == self.bitchesBrew { throw self.failure("Disk full") }
            return try self.copySource(copy)
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

        let outcome = executor.run(plan, source: copySource)

        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.failedDeletions.isEmpty)
        XCTAssertEqual(outcome.alreadyGone, [gone])
        XCTAssertEqual(outcome.removedPaths, [gone.path], "the catalog still drops a file that is already gone")
    }

    // MARK: - Temp files

    func testCopiesAreWrittenToATempFirst() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        var sourceAskedFor: URL?

        _ = executor.run(plan([new]), source: { copy in
            sourceAskedFor = copy.destinationURL
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.destinationURL.path),
                           "nothing under the final name while writing")
            return try self.copySource(copy)
        })

        // The door writes "<name>.cdtmp" beside the destination and renames it.
        XCTAssertEqual(DeviceFileIO.tempURL(for: new.destinationURL).lastPathComponent, "01 So What.flac.cdtmp")
        XCTAssertEqual(sourceAskedFor, new.destinationURL)
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "new")
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"],
                       "the temp is renamed away")
    }

    func testFailedCopyLeavesNothingAtTheDestination() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let folder = new.destinationURL.deletingLastPathComponent()
        let half = source.appendingPathComponent("half.flac")

        let outcome = executor.run(plan([new]), source: { _ in
            try "half a fi".write(to: half, atomically: false, encoding: .utf8)
            throw self.failure("Device unplugged")
        })

        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.destinationURL.path))
        XCTAssertEqual(leftovers(in: folder), [], "the partial is removed too")
    }

    func testCopyThatFailsOnTheDeviceLeavesNoTempAndNoFolder() throws {
        let new = try copyItem("01 So What.flac", to: "New Artist/New Album/01 So What.flac", album: kindOfBlue)
        // A folder where a file should be: the device write itself fails.
        let notAFile = source.appendingPathComponent("not a file", isDirectory: true)
        try FileManager.default.createDirectory(at: notAFile, withIntermediateDirectories: true)

        let outcome = executor.run(plan([new]), source: { _ in notAFile })

        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertEqual(leftovers(in: device), [], "no temp, and no folder the failed write made")
    }

    func testFailedOverwriteKeepsTheOldFile() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old art")
        let swap = try copyItem("01 So What.mp3", to: "Miles Davis/Kind of Blue/01 So What.mp3",
                                album: kindOfBlue, overwrites: true, contents: "new art")

        let outcome = executor.run(plan([swap]), source: { _ in
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

        let outcome = executor.run(plan([swap]), source: copySource)

        XCTAssertEqual(outcome.written, [swap])
        XCTAssertEqual(try String(contentsOf: swap.destinationURL, encoding: .utf8), "new art")
        XCTAssertEqual(leftovers(in: swap.destinationURL.deletingLastPathComponent()), ["01 So What.mp3"])
    }

    func testAppearedFileFailsThatItemOnly() throws {
        let taken = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let free = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.flac", album: kindOfBlue)
        // Someone else's file landed at the planned name after the review.
        try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "theirs")

        let outcome = executor.run(plan([taken, free]), source: copySource)

        XCTAssertEqual(outcome.failed.map(\.copy), [taken])
        XCTAssertEqual(outcome.failed.first?.reason, DeviceTransferExecutor.appearedReason)
        XCTAssertEqual(try String(contentsOf: taken.destinationURL, encoding: .utf8), "theirs", "never overwritten")
        XCTAssertEqual(outcome.written, [free])
    }

    func testAppearedFileIsCheckedBeforeTheRename() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)

        // The file lands while the copy is being made, after the first check.
        let outcome = executor.run(plan([new]), source: { copy in
            let bytes = try self.copySource(copy)
            try self.file(self.device, "Miles Davis/Kind of Blue/01 So What.flac", "theirs")
            return bytes
        })

        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertEqual(outcome.failed.first?.reason, DeviceTransferExecutor.appearedReason)
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "theirs")
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"])
    }

    func testLeftoverPartialFromACrashIsReplaced() throws {
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        let stale = DeviceFileIO.tempURL(for: new.destinationURL)
        try file(device, "Miles Davis/Kind of Blue/\(stale.lastPathComponent)", "stale half")
        // The crashed session said it would make that temp: only then is it ours to clear.
        try executor.door.journal.append([DeviceFileRecord(
            relativePath: "Music/Miles Davis/Kind of Blue/\(stale.lastPathComponent)", kind: .tempIntent,
            role: DeviceFileRole.temp.rawValue, volumeUUID: "TEST-VOLUME", sessionID: UUID())])

        let outcome = executor.run(plan([new]), source: copySource)

        XCTAssertEqual(outcome.written, [new])
        XCTAssertEqual(try String(contentsOf: new.destinationURL, encoding: .utf8), "new")
        XCTAssertEqual(leftovers(in: new.destinationURL.deletingLastPathComponent()), ["01 So What.flac"])
    }

    // MARK: - The convert side's finish step

    func testFinishMovesAConvertedFileIntoPlaceAndRefusesAnAppearedFile() throws {
        let copy = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        let staged = try file(scratch, "Staging/0/01 So What.mp3", "encoded")
        XCTAssertEqual(staged.pathExtension, "mp3", "ffmpeg still sees .mp3")

        try executor.write(copy, from: { _ in staged })
        XCTAssertEqual(try String(contentsOf: copy.destinationURL, encoding: .utf8), "encoded")
        XCTAssertEqual(leftovers(in: copy.destinationURL.deletingLastPathComponent()), ["01 So What.mp3"])

        // A second run of the same name while a file now sits there.
        let again = try file(scratch, "Staging/1/01 So What.mp3", "encoded again")
        XCTAssertThrowsError(try executor.write(copy, from: { _ in again })) { error in
            XCTAssertEqual(error.localizedDescription, DeviceTransferExecutor.appearedReason)
        }
        XCTAssertEqual(try String(contentsOf: copy.destinationURL, encoding: .utf8), "encoded")
        XCTAssertEqual(leftovers(in: copy.destinationURL.deletingLastPathComponent()), ["01 So What.mp3"])

        // Cleared for overwriting, the same write replaces it.
        let replace = try file(scratch, "Staging/2/01 So What.mp3", "re-encoded")
        let swap = DeviceTransferFilePlan.Copy(source: copy.source, destinationURL: copy.destinationURL,
                                               overwrites: true, kind: .replacement, album: kindOfBlue)
        try executor.write(swap, from: { _ in replace })
        XCTAssertEqual(try String(contentsOf: copy.destinationURL, encoding: .utf8), "re-encoded")
    }

    // MARK: - Progress, cancel, unplanned

    func testCreatesMissingFoldersAndReportsProgress() throws {
        let one = try copyItem("01 A.flac", to: "New Artist/New Album/01 A.flac", album: kindOfBlue)
        let two = try copyItem("02 B.flac", to: "New Artist/New Album/02 B.flac", album: kindOfBlue)
        var steps: [Int] = []

        let outcome = executor.run(plan([one, two]), source: copySource, onProgress: { done, total in
            XCTAssertEqual(total, 2)
            steps.append(done)
        })

        XCTAssertEqual(steps, [1, 2])
        XCTAssertEqual(outcome.written, [one, two])
    }

    func testCancelledCopiesFailAndKeepTheirAlbumsOldFiles() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "old")
        let new = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)

        let outcome = executor.run(plan([new], deletions: [kindOfBlue: [old]]), source: copySource, isCancelled: { true })

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
            source: { copy in
                cancelled = true   // the user presses Cancel while this copy runs
                return try self.copySource(copy)
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

        var outcome = executor.runCopies(plan, source: copySource)
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

    // MARK: - Albums the policy refuses as a whole

    /// An album an older version filed under "R.E.M." (a trailing dot the
    /// policy refuses): a Gaps fill into it fails as a whole, with one
    /// message naming the folder, and nothing of it is written.
    func testAlbumInARefusedFolderFailsAsAWholeBeforeAnythingIsWritten() throws {
        let rem = DeviceAlbumIdentity(artist: "R.E.M.", album: "Document")
        let gap = try copyItem("02 Exhuming.flac", to: "R.E.M./Document/02 Exhuming.flac", album: rem)
        let fine = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.flac", album: kindOfBlue)
        var asked: [DeviceAlbumIdentity] = []

        let outcome = executor.run(plan([gap, fine]), source: { copy in
            asked.append(copy.album)
            return try self.copySource(copy)
        })

        XCTAssertEqual(asked, [kindOfBlue], "nothing is spent on the refused album")
        XCTAssertEqual(outcome.written, [fine])
        XCTAssertEqual(outcome.failed.first?.reason,
                       "Rename \"R.E.M.\" on the device so it does not end in a dot, then send again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gap.destinationURL.path))
    }

    /// A Replace whose old files sit in a refused folder: the new copies do
    /// not land either, so it never ends half replaced.
    func testReplaceWithARefusedDeletionWritesNothing() throws {
        let rem = DeviceAlbumIdentity(artist: "R.E.M.", album: "Document")
        let old = try file(device, "R.E.M./Document/01 Finest Worksong.mp3", "old")
        let new = try copyItem("01 Finest Worksong.flac", to: "R.E.M/Document/01 Finest Worksong.flac", album: rem)

        let outcome = executor.run(plan([new], deletions: [rem: [old]]), source: copySource)

        XCTAssertTrue(outcome.written.isEmpty)
        XCTAssertEqual(outcome.failed.map(\.copy), [new])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the old album stays whole")
        XCTAssertTrue(outcome.deleted.isEmpty)
    }

    func testUnplannedTracksAreListedAsFailures() throws {
        let lost = track(at: source.appendingPathComponent("lost.flac"))
        let plan = DeviceTransferFilePlan(
            copies: [], deletionsByAlbum: [:], coverFolders: [:], skippedPresent: 0,
            leftAlone: 0, replacedAlbums: 0, keptBothAlbums: 0, gapAlbums: 0, unplanned: [lost]
        )

        let outcome = executor.run(plan, source: copySource)

        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("[FAILED] lost.flac") })
    }

    // MARK: - Fixtures

    /// The library file itself, as the copy path sends it.
    private func copySource(_ copy: DeviceTransferFilePlan.Copy) throws -> URL {
        copy.source.track.fileURL
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
