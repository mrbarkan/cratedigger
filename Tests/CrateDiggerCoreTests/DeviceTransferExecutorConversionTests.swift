#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The converting side of a device run against a temp-dir "device": what is
/// held back before the ffmpeg batch, which partials become files after it,
/// which deletions are earned, and which folders are left. ffmpeg itself is
/// stood in for by writing the partials the way `ConversionService` would
/// (it creates the folder when a job runs).
final class DeviceTransferExecutorConversionTests: XCTestCase {
    private let executor = DeviceTransferExecutor()
    private var scratch: URL!
    private var source: URL!
    private var device: URL!
    private let kindOfBlue = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
    private let bitchesBrew = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferExecutorConversionTests-\(UUID().uuidString)", isDirectory: true)
        scratch = base.resolvingSymlinksInPath()
        source = scratch.appendingPathComponent("Library", isDirectory: true)
        device = scratch.appendingPathComponent("IPOD/Music", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Before the batch

    func testPartialJobsCreateNoFolders() throws {
        let copy = try copyItem("01 A.flac", to: "New Artist/New Album (2)/01 A.mp3", album: bitchesBrew)

        let jobs = executor.partialJobs(for: plan([copy]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("New Artist").path),
                       "a folder is made by the job that writes into it, never up front")
        XCTAssertEqual(jobs.jobs.map(\.destinationURL.lastPathComponent), [".cdpart.01 A.mp3"])
        XCTAssertEqual(jobs.newFolders[copy.destinationURL.path]?.lastPathComponent, "New Artist")
    }

    func testPartialJobsHoldBackAnAppearedFileAndClearALeftoverPartial() throws {
        let appeared = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        try file(device, "Miles Davis/Kind of Blue/01 So What.mp3", "theirs")
        let other = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.mp3", album: kindOfBlue)
        let stale = try file(device, "Miles Davis/Kind of Blue/.cdpart.02 Freddie.mp3", "half")

        let jobs = executor.partialJobs(for: plan([appeared, other]))

        XCTAssertEqual(jobs.heldBack, [appeared.destinationURL.path: DeviceTransferExecutor.appearedReason])
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testSliceJobsCutTheirPartOfTheSource() throws {
        let copy = try copyItem("Side A.flac", to: "Artist/Album/02 Second.mp3", album: kindOfBlue)
        let slice = ConversionJob(sourceURL: copy.source.track.fileURL, destinationURL: copy.destinationURL,
                                  metadata: ConversionMetadata(title: "Second"), startSeconds: 200, endSeconds: 410)

        let jobs = executor.partialJobs(for: plan([copy]), slices: [copy.destinationURL.path: slice])

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
        let jobs = executor.partialJobs(for: plan)
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
        let jobs = executor.partialJobs(for: plan)
        let partials = try runFakeBatch(jobs)

        let outcome = executor.finishConverted(
            plan, jobs: jobs,
            succeeded: [partials[landed.destinationURL.path]!.path],
            reasons: [:],
            wasCancelled: false
        )

        XCTAssertEqual(outcome.failed.first { $0.copy == failed }?.reason, "Could not be converted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("Miles Davis").path),
                       "a Keep both folder nothing landed in is gone, so the next one is (2) again")
        XCTAssertEqual(leftovers(in: landed.destinationURL.deletingLastPathComponent()), ["01 A.mp3"],
                       "a folder a file landed in stays")
    }

    func testCancelledRunEarnsNoDeletions() throws {
        let old = try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let blue = try copyItem("01 So What.flac", to: "Miles Davis/Kind of Blue/01 So What.mp3", album: kindOfBlue)
        let plan = plan([blue], deletions: [kindOfBlue: [old]])
        let jobs = executor.partialJobs(for: plan)
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
        let jobs = executor.partialJobs(for: plan)
        let partials = try runFakeBatch(jobs)

        let outcome = executor.finishConverted(
            plan, jobs: jobs, succeeded: Set(partials.values.map(\.path)), reasons: [:],
            wasCancelled: false, isCancelled: { true }
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    // MARK: - Writes through the executor (copy path, SYNC)

    func testFailedWriteRemovesTheFolderItCreated() throws {
        let copy = try copyItem("01 A.flac", to: "New Artist/New Album/01 A.flac", album: bitchesBrew)

        XCTAssertThrowsError(try executor.write(copy) { _, _ in throw self.failure("disk full") })

        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("New Artist").path))
        XCTAssertEqual(leftovers(in: device), [])
    }

    func testFailedWriteKeepsAFolderThatWasThere() throws {
        try file(device, "Miles Davis/Kind of Blue/01 So What.flac", "old")
        let copy = try copyItem("02 Freddie.flac", to: "Miles Davis/Kind of Blue/02 Freddie.flac", album: kindOfBlue)

        XCTAssertThrowsError(try executor.write(copy) { _, _ in throw self.failure("disk full") })

        XCTAssertEqual(leftovers(in: device.appendingPathComponent("Miles Davis/Kind of Blue")), ["01 So What.flac"])
    }

    // MARK: - The rename refuses an existing name

    /// A file landing between any check and the move: the exclusive rename
    /// itself refuses it.
    func testExclusiveRenameRefusesAFileThatAppearsAtTheLastInstant() throws {
        let destination = try folder("Miles Davis/Kind of Blue").appendingPathComponent("01 So What.mp3")
        let racing = DeviceTransferExecutor(fileManager: .default) { from, to in
            try? "theirs".write(toFile: to, atomically: true, encoding: .utf8)
            return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
        let partial = try file(device, "Miles Davis/Kind of Blue/.cdpart.01 So What.mp3", "encoded")

        XCTAssertThrowsError(try racing.finish(partial, onto: destination, overwrites: false)) { error in
            XCTAssertEqual(error.localizedDescription, DeviceTransferExecutor.appearedReason)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "theirs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    /// FAT returns ENOTSUP for RENAME_EXCL: the check right before a plain
    /// rename stands in.
    func testWithoutExclusiveRenameTheCheckStandsIn() throws {
        let fat = DeviceTransferExecutor(fileManager: .default) { _, _ in ENOTSUP }
        let destination = try folder("Miles Davis/Kind of Blue").appendingPathComponent("01 So What.mp3")

        let first = try file(device, "Miles Davis/Kind of Blue/.cdpart.01 So What.mp3", "encoded")
        try fat.finish(first, onto: destination, overwrites: false)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")

        let second = try file(device, "Miles Davis/Kind of Blue/.cdpart.01 So What.mp3", "again")
        XCTAssertThrowsError(try fat.finish(second, onto: destination, overwrites: false)) { error in
            XCTAssertEqual(error.localizedDescription, DeviceTransferExecutor.appearedReason)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testOtherRenameErrorsFailTheItem() throws {
        let broken = DeviceTransferExecutor(fileManager: .default) { _, _ in EIO }
        let destination = try folder("Miles Davis/Kind of Blue").appendingPathComponent("01 So What.mp3")
        let partial = try file(device, "Miles Davis/Kind of Blue/.cdpart.01 So What.mp3", "encoded")

        XCTAssertThrowsError(try broken.finish(partial, onto: destination, overwrites: false)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not move the finished file into place"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Fixtures

    /// Writes each job's partial the way a conversion run would: the job's
    /// folder made as it starts. Returns the partials by destination path.
    private func runFakeBatch(_ jobs: DeviceTransferExecutor.PartialJobs) throws -> [String: URL] {
        for job in jobs.jobs {
            try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "encoded".write(to: job.destinationURL, atomically: true, encoding: .utf8)
        }
        return jobs.partials
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
