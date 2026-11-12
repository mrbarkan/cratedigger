#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The converting side of a device run against a temp-dir "device": what is
/// held back before the ffmpeg batch, which staged files land after it,
/// which deletions are earned, and which folders are left. ffmpeg never
/// writes onto the device: it is stood in for by writing the staged files on
/// the "Mac" the way `ConversionService` would (it creates the folder when a
/// job runs), and the door copies them over.
final class DeviceTransferExecutorConversionTests: XCTestCase {
    private var executor: DeviceTransferExecutor!
    private var scratch: URL!
    private var source: URL!
    private var volume: URL!
    private var device: URL!
    private var staging: URL!
    private let kindOfBlue = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
    private let bitchesBrew = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferExecutorConversionTests-\(UUID().uuidString)", isDirectory: true)
        scratch = base.resolvingSymlinksInPath()
        source = scratch.appendingPathComponent("Library", isDirectory: true)
        volume = scratch.appendingPathComponent("IPOD", isDirectory: true)
        device = volume.appendingPathComponent("Music", isDirectory: true)
        staging = scratch.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        executor = DeviceTransferExecutor(door: .onTempFolder(
            volume, musicSubpath: "Music", journalDirectory: scratch.appendingPathComponent("Journal")))
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Before the batch

    func testStagedJobsCreateNoFolders() throws {
        let copy = try copyItem("01 A.flac", to: "New Artist/New Album (2)/01 A.mp3", album: bitchesBrew)

        let jobs = executor.stagedJobs(for: plan([copy]), stagingRoot: staging)

        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("New Artist").path),
                       "nothing is made on the device before a file lands there")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the job makes its own staging folder")
        XCTAssertEqual(jobs.jobs.map(\.destinationURL), [staging.appendingPathComponent("0/01 A.mp3")],
                       "on the Mac, the real extension last: ffmpeg picks its muxer from it")
        XCTAssertEqual(jobs.staged[copy.destinationURL.path], staging.appendingPathComponent("0/01 A.mp3"))
    }

    func testStagedJobsHoldBackAnAppearedFileAndLeaveAForeignPartial() throws {
        let appeared = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "theirs")
        let other = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.mp3", album: kindOfBlue)
        // A partial an older version left: not proven ours, so not deleted.
        let stale = try file(device, "Miles Davis/Kind of Blue/.cdpart.02 Freddie.mp3", "half")

        let jobs = executor.stagedJobs(for: plan([appeared, other]), stagingRoot: staging)

        XCTAssertEqual(jobs.heldBack, [appeared.destinationURL.path: DeviceTransferExecutor.appearedReason])
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }

    func testStagedJobsHoldBackWhatThePolicyRefusesAndWhatTheMacCannotHold() throws {
        let refused = try copyItem("01 A.flac", to: "Vol./01 A.mp3", album: kindOfBlue)
        let fits = try copyItem("02 B.flac", to: "Album/02 B.mp3", album: kindOfBlue)
        let tooMuch = try copyItem("03 C.flac", to: "Album/03 C.mp3", album: kindOfBlue)
        let margin = DeviceTransferExecutor.stagingSpaceMargin

        let jobs = executor.stagedJobs(for: plan([refused, fits, tooMuch]), stagingRoot: staging,
                                       stagingBytesAvailable: margin + 150, estimatedBytes: { _ in 100 })

        XCTAssertEqual(jobs.heldBack[refused.destinationURL.path],
                       "CrateDigger does not write there: a name ending in a dot or a space")
        XCTAssertEqual(jobs.heldBack[tooMuch.destinationURL.path], DeviceTransferExecutor.stagingSpaceReason)
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertNotNil(jobs.staged[fits.destinationURL.path])
    }

    func testSliceJobsCutTheirPartOfTheSource() throws {
        let copy = try copyItem("Side A.flac", to: "Artist/Album/02 Second.mp3", album: kindOfBlue)
        let slice = ConversionJob(sourceURL: copy.source.track.fileURL, destinationURL: copy.destinationURL,
                                  metadata: ConversionMetadata(title: "Second"), startSeconds: 200, endSeconds: 410)

        let jobs = executor.stagedJobs(for: plan([copy]), stagingRoot: staging, slices: [copy.destinationURL.path: slice])

        XCTAssertEqual(jobs.jobs.first?.startSeconds, 200)
        XCTAssertEqual(jobs.jobs.first?.endSeconds, 410)
        XCTAssertEqual(jobs.jobs.first?.metadata?.title, "Second")
    }

    // MARK: - After the batch

    func testFailedJobKeepsItsAlbumsOldFilesAndLeavesNoPartial() throws {
        let oldBlue = try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let oldBrew = try file(device, "Miles Davis/Bitches Brew/01 Pharaoh's Dance.flac", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        let brew = try copyItem("01 Pharaoh's Dance.flac", to: "Miles Davis/Bitches Brew/01 Pharaoh's Dance.mp3",
                                album: bitchesBrew)
        let plan = plan([blue, brew], deletions: [kindOfBlue: [oldBlue], bitchesBrew: [oldBrew]])
        let jobs = executor.stagedJobs(for: plan, stagingRoot: staging)
        // ffmpeg: Kind of Blue's job dies halfway, Bitches Brew's completes.
        let partials = try runFakeBatch(jobs)

        let outcome = executor.finishConverted(
            plan, jobs: jobs,
            succeeded: [partials[brew.destinationURL.path]!.path],
            reasons: [partials[blue.destinationURL.path]!.path: "Invalid data found when processing input"],
            wasCancelled: false
        )

        XCTAssertEqual(outcome.written, [brew])
        XCTAssertEqual(outcome.failed.map(\.copy), [blue])
        XCTAssertEqual(outcome.failed.first?.reason, "Invalid data found when processing input")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlue.path), "a failed job keeps its album's old files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBrew.path))
        XCTAssertEqual(leftovers(in: oldBlue.deletingLastPathComponent()), ["01 So What.flac"], "no partial left")
        XCTAssertEqual(leftovers(in: oldBrew.deletingLastPathComponent()), ["01 Pharaoh's Dance.mp3"])
    }

    func testFailedJobRemovesTheFolderItsWriteCreated() throws {
        let landed = try copyItem("01 A.flac", to: "New Artist/Album/01 A.mp3", album: bitchesBrew)
        let failed = try copyItem("01 B.flac", to: "Miles Davis/Kind of Blue (2)/01 B.mp3", album: kindOfBlue)
        let failedToo = try copyItem("02 C.flac", to: "New Artist/Album/02 C.mp3", album: bitchesBrew)
        let plan = plan([landed, failed, failedToo])
        let jobs = executor.stagedJobs(for: plan, stagingRoot: staging)
        let partials = try runFakeBatch(jobs)

        let outcome = executor.finishConverted(
            plan, jobs: jobs,
            succeeded: [partials[landed.destinationURL.path]!.path],
            reasons: [:],
            wasCancelled: false
        )

        XCTAssertEqual(outcome.failed.first { $0.copy == failed }?.reason, "Could not be converted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("Miles Davis").path),
                       "a Keep both folder nothing landed in is never made, so the next one is (2) again")
        XCTAssertEqual(leftovers(in: landed.destinationURL.deletingLastPathComponent()), ["01 A.mp3"],
                       "a folder a file landed in stays")
    }

    func testCancelledRunEarnsNoDeletions() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        let plan = plan([blue], deletions: [kindOfBlue: [old]])
        let jobs = executor.stagedJobs(for: plan, stagingRoot: staging)
        let partials = try runFakeBatch(jobs)

        // Every job finished; Cancel was pressed after the last was dispatched.
        let outcome = executor.finishConverted(
            plan, jobs: jobs, succeeded: Set(partials.values.map(\.path)), reasons: [:], wasCancelled: true
        )

        XCTAssertEqual(outcome.written, [blue], "a finished file is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertEqual(outcome.deletionsSkipped, [kindOfBlue])
    }

    func testCancelDuringTheRenamesEarnsNoDeletions() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        let plan = plan([blue], deletions: [kindOfBlue: [old]])
        let jobs = executor.stagedJobs(for: plan, stagingRoot: staging)
        let partials = try runFakeBatch(jobs)

        let outcome = executor.finishConverted(
            plan, jobs: jobs, succeeded: Set(partials.values.map(\.path)), reasons: [:],
            wasCancelled: false, isCancelled: { true }
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blue.destinationURL.path),
                       "a cancel stops the copies that have not started")
    }

    // MARK: - Writes through the executor (copy path, SYNC)

    func testFailedWriteRemovesTheFolderItCreated() throws {
        let copy = try copyItem("01 A.flac", to: "New Artist/New Album/01 A.flac", album: bitchesBrew)

        // Fails before the device is touched...
        XCTAssertThrowsError(try executor.write(copy) { _ in throw self.failure("disk full") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("New Artist").path))
        // ...and fails in the device write itself, after the door made the folders.
        XCTAssertThrowsError(try executor.write(copy) { _ in self.scratch.appendingPathComponent("gone.flac") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("New Artist").path))
        XCTAssertEqual(leftovers(in: device), [])
    }

    func testFailedWriteKeepsAFolderThatWasThere() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let copy = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.flac", album: kindOfBlue)

        XCTAssertThrowsError(try executor.write(copy) { _ in throw self.failure("disk full") })
        XCTAssertThrowsError(try executor.write(copy) { _ in self.scratch.appendingPathComponent("gone.flac") })

        XCTAssertEqual(leftovers(in: device.appendingPathComponent("Miles Davis/Kind of Blue")), ["01 So What.flac"])
    }

    // MARK: - The rename refuses an existing name

    /// A file landing between any check and the move: the exclusive rename
    /// itself refuses it (`renamex_np(RENAME_EXCL)` on APFS and HFS).
    func testExclusiveRenameRefusesAFileThatAppearsAtTheLastInstant() throws {
        let destination = try folder("Miles Davis/Kind of Blue").appendingPathComponent("01 So What.mp3")
        let encoded = try file(scratch, "Staging/0/01 So What.mp3", "encoded")
        try "theirs".write(to: destination, atomically: true, encoding: .utf8)   // landed at the last instant

        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: encoded, to: destination, exclusive: true)) { error in
            XCTAssertEqual((error as? DeviceFileIOError)?.code, EEXIST)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "theirs")
        XCTAssertEqual(leftovers(in: destination.deletingLastPathComponent()), ["01 So What.mp3"], "no temp left")
    }

    /// FAT returns ENOTSUP for RENAME_EXCL: the check right before a plain
    /// rename stands in. (APFS here; `FATSandboxTests` runs it on real FAT.)
    func testWithoutExclusiveRenameTheCheckStandsIn() throws {
        let destination = try folder("Miles Davis/Kind of Blue").appendingPathComponent("01 So What.mp3")

        let first = try file(scratch, "Staging/0/01 So What.mp3", "encoded")
        try DeviceFileIO.copyDataOnly(from: first, to: destination, exclusive: true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")

        let second = try file(scratch, "Staging/1/01 So What.mp3", "again")
        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: second, to: destination, exclusive: true)) { error in
            XCTAssertEqual((error as? DeviceFileIOError)?.code, EEXIST)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeviceFileIO.tempURL(for: destination).path))
    }

    func testOtherRenameErrorsFailTheItem() throws {
        // A folder holding a file sits at the name: a rename cannot replace it.
        let destination = try folder("Miles Davis/Kind of Blue/01 So What.mp3")
        try file(destination, "inside", "x")
        let encoded = try file(scratch, "Staging/0/01 So What.mp3", "encoded")

        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: encoded, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Rename failed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeviceFileIO.tempURL(for: destination).path))
        XCTAssertEqual(leftovers(in: destination), ["inside"])
    }

    // MARK: - Fixtures

    /// Writes each job's staged file the way a conversion run would: the
    /// job's folder made as it starts. Returns the staged files by destination path.
    private func runFakeBatch(_ jobs: DeviceTransferExecutor.StagedJobs) throws -> [String: URL] {
        for job in jobs.jobs {
            XCTAssertTrue(job.destinationURL.path.hasPrefix(staging.path), "ffmpeg never writes onto the device")
            try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "encoded".write(to: job.destinationURL, atomically: true, encoding: .utf8)
        }
        return jobs.staged
    }

    private func failure(_ reason: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private func leftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func folder(_ relative: String) throws -> URL {
        let url = device.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        overwrites: Bool = false
    ) throws -> DeviceTransferFilePlan.Copy {
        let sourceURL = try file(source, name, "source")
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let audio = AudioTrack(fileURL: sourceURL, title: title, artist: "Miles Davis", album: album.album)
        return DeviceTransferFilePlan.Copy(
            source: LoadedTrack(track: audio, metadata: ConversionMetadata(title: title)),
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
}
#endif
