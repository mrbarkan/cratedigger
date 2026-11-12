import Darwin
import XCTest
@testable import CrateDiggerCore

/// The sweep plan lists a `._` file only with the whole proof (spec D20, D21):
/// a regular file, 26 bytes to 128 KB, the AppleDouble magic and version, the
/// twin of a media name, outside the player's trees. Every clause has a
/// look-alike here that must survive, and the plan itself never deletes.
final class AppleDoubleSweeperTests: XCTestCase {
    private var iPod: FakeIPod!
    private var before: [String: String] = [:]
    private let album = "Music/Classics/Beach House/2010 Teen Dream"

    override func setUpWithError() throws {
        iPod = try FakeIPod()
        before = try iPod.manifest()
    }

    override func tearDownWithError() throws {
        iPod.assertPlayerStateUntouched(since: before)
        iPod = nil
    }

    func testFoldersUnderAFolderMakeARecursiveScope() throws {
        try addTwin("\(album)/CD1/._01.m4a")
        try addTwin("\(album)/CD2/._01.m4a")
        try addTwin("Music/Classics/Other/._01.m4a")
        let folders = AppleDoubleSweeper.folders(under: iPod.root.appendingPathComponent(album, isDirectory: true))
        XCTAssertEqual(folders.map { $0.lastPathComponent }, ["2010 Teen Dream", "CD1", "CD2"])
        let scoped = sweeper.plan(volumeRoot: iPod.root, scope: folders,
                                  mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
        XCTAssertEqual(scoped.candidates, ["\(album)/CD1/._01.m4a", "\(album)/CD2/._01.m4a"])
        XCTAssertEqual(AppleDoubleSweeper.folders(under: iPod.root).filter { $0.lastPathComponent == ".rockbox" }, [],
                       "never into the player's trees")
    }

    // MARK: Helpers

    private func plan(scope: [String]? = nil) -> AppleDoubleSweepPlan {
        sweeper.plan(volumeRoot: iPod.root,
                                  scope: scope?.map { iPod.root.appendingPathComponent($0, isDirectory: true) },
                                  mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
    }

    /// The FakeIPod is a temp folder on APFS; the sweep is told it is FAT.
    private let sweeper = AppleDoubleSweeper(fileSystemType: { _ in "msdos" })

    private func addTwin(_ relativePath: String, _ data: Data = FakeIPod.appleDoubleBytes()) throws {
        try iPod.addFile(relativePath, data)
    }

    /// `._` files included (Foundation's listings leave them out).
    private func allFiles() -> [String] { iPod.allRelativePaths() }

    // MARK: Acceptances

    func testFindsTwinsOfAudio() throws {
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a", "02 - Silver Soul.flac"], appleDoubleTwins: true)
        let result = plan()
        XCTAssertEqual(result.candidates, ["\(album)/._01 - Zebra.m4a",
                                           "\(album)/._02 - Silver Soul.flac",
                                           "\(album)/._cover.jpg"])
        XCTAssertEqual(result.leftAlone, [:])
        XCTAssertEqual(result.sizeHistogram, [4096: 3])
    }

    func testOrphanTwinQualifies() throws {
        try addTwin("Music/A/B/._gone.mp3")
        XCTAssertEqual(plan().candidates, ["Music/A/B/._gone.mp3"])
    }

    func testSizeBoundsAreInclusive() throws {
        try addTwin("Music/A/._smallest.mp3", FakeIPod.appleDoubleBytes(size: 26))
        try addTwin("Music/A/._largest.mp3", FakeIPod.appleDoubleBytes(size: 128 * 1024))
        let result = plan()
        XCTAssertEqual(result.candidates, ["Music/A/._largest.mp3", "Music/A/._smallest.mp3"])
        XCTAssertEqual(result.sizeHistogram, [32: 1, 131_072: 1])
    }

    func testMediaExtensionIsCaseInsensitive() throws {
        try addTwin("Music/A/._COVER.JPG")
        try addTwin("Playlists/._Mix.M3U8")
        XCTAssertEqual(plan().candidates, ["Music/A/._COVER.JPG", "Playlists/._Mix.M3U8"])
    }

    func testDefaultMediaExtensionsCoverAudioPicturesPlaylistsAndText() {
        let media = AppleDoubleSweeper.defaultMediaExtensions
        XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.isSubset(of: media))
        for ext in ["jpg", "jpeg", "png", "bmp", "gif", "webp", "m3u", "m3u8", "lrc", "lrc8", "snc",
                    "epub", "pdf", "cue"] {
            XCTAssertTrue(media.contains(ext), ext)
        }
        XCTAssertFalse(media.contains("txt"))
        XCTAssertFalse(media.contains("cfg"))
    }

    func testIsAppleDoubleHeader() {
        XCTAssertTrue(AppleDoubleSweeper.isAppleDouble(header: FakeIPod.appleDoubleBytes(size: 8)))
        XCTAssertFalse(AppleDoubleSweeper.isAppleDouble(header: Data([0x00, 0x05, 0x16, 0x07])))
        XCTAssertFalse(AppleDoubleSweeper.isAppleDouble(header: Data([0x00, 0x05, 0x16, 0x00, 0x00, 0x02, 0x00, 0x00])))
    }

    // MARK: Look-alikes that must survive

    func testRealAudioNamedLikeATwinSurvives() throws {
        try iPod.addFile("Music/A/._x.m4a", Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not AppleDouble": 1])
    }

    func testDirectoryNamedLikeATwinSurvives() throws {
        try FileManager.default.createDirectory(at: iPod.root.appendingPathComponent("Music/A/._dir.mp3"),
                                                withIntermediateDirectories: true)
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not a file": 1])
    }

    func testTwinInsideAFolderNamedLikeATwinIsStillFound() throws {
        try addTwin("Music/._odd/._x.mp3")
        let result = plan()
        XCTAssertEqual(result.candidates, ["Music/._odd/._x.mp3"])
        XCTAssertEqual(result.leftAlone, ["not a file": 1])
    }

    func testSymlinkSurvives() throws {
        let real = try iPod.addFile("Music/A/real-twin.bin", FakeIPod.appleDoubleBytes())
        try FileManager.default.createSymbolicLink(atPath: iPod.root.appendingPathComponent("Music/A/._x.mp3").path,
                                                   withDestinationPath: real.path)
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not a file": 1])
    }

    func testSymlinkedFolderIsNotFollowed() throws {
        try addTwin(".rockbox/themes/._x.jpg")
        try FileManager.default.createSymbolicLink(atPath: iPod.root.appendingPathComponent("Music/themes").path,
                                                   withDestinationPath: "../.rockbox/themes")
        before = try iPod.manifest()
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, [:])
    }

    func testTenByteFileSurvives() throws {
        try addTwin("Music/A/._x.mp3", FakeIPod.appleDoubleBytes(size: 10))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not AppleDouble": 1])
    }

    func testTwentyFiveBytesSurvives() throws {
        try addTwin("Music/A/._x.mp3", FakeIPod.appleDoubleBytes(size: 25))
        XCTAssertEqual(plan().leftAlone, ["not AppleDouble": 1])
    }

    func testAppleSingleMagicSurvives() throws {
        try addTwin("Music/A/._x.mp3", Data([0x00, 0x05, 0x16, 0x00, 0x00, 0x02, 0x00, 0x00]) + Data(count: 4088))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not AppleDouble": 1])
    }

    func testWrongVersionSurvives() throws {
        try addTwin("Music/A/._x.mp3", Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x01, 0x00, 0x00]) + Data(count: 4088))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not AppleDouble": 1])
    }

    func testOversizeTwinIsLeftAndCounted() throws {
        try addTwin("Music/A/._x.mp3", FakeIPod.appleDoubleBytes(size: 129 * 1024))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone["too large"], 1)
        XCTAssertEqual(result.leftAlone.count, 1)
        XCTAssertEqual(result.sizeHistogram, [:])
    }

    func testNonMediaTwinIsLeftAndCounted() throws {
        try addTwin("Notes/._todo.txt")
        try addTwin("Music/A/._README") // no extension at all
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not media": 2])
    }

    func testBareDotUnderscoreIsNotATwin() throws {
        try addTwin("Music/A/._")
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, [:])
    }

    func testNothingUnderDeniedTreesIsListed() throws {
        try addTwin(".rockbox/themes/._x.jpg")
        try addTwin(".rockbox_backup/._x.mp3")
        try addTwin("iPod_Control/Music/._x.mp3")
        try addTwin(".Trashes/501/._x.mp3")
        try addTwin(".Spotlight-V100/._x.jpg")
        try addTwin(".fseventsd/._x.jpg")
        try addTwin(".backup/._x.m4a")
        // The policy refuses a denied name at any depth; so does the sweep.
        try addTwin("Music/.rockbox/._x.m4a")
        before = try iPod.manifest()
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, [:])
        // A scope that names a denied tree is refused too.
        XCTAssertEqual(plan(scope: [".rockbox/themes", "iPod_Control/Music", "Music/.rockbox"]).candidates, [])
        XCTAssertTrue(allFiles().contains("Music/.rockbox/._x.m4a"))
    }

    func testPathThePolicyRefusesIsNotListed() throws {
        try addTwin("Music/.../._x.mp3")
        XCTAssertThrowsError(try DeviceWritePolicy(musicSubpath: "Music")
            .checkDelete("Music/.../._x.mp3", reason: .appleDouble))
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not allowed here": 1])
    }

    // MARK: Which volumes

    func testRefusesToPlanOffFATAndExFAT() throws {
        try addTwin("Music/A/._x.mp3")
        // The real file system of the temp folder: APFS.
        let real = AppleDoubleSweeper().plan(volumeRoot: iPod.root, scope: nil)
        XCTAssertEqual(AppleDoubleSweeper.systemFileSystemType(iPod.root), "apfs")
        XCTAssertEqual(real.candidates, [])
        XCTAssertEqual(real.leftAlone, [:])
        XCTAssertNotNil(real.refusal)
        for type in ["hfs", "apfs", "smbfs", nil] as [String?] {
            let result = AppleDoubleSweeper(fileSystemType: { _ in type }).plan(volumeRoot: iPod.root, scope: nil)
            XCTAssertEqual(result.candidates, [], String(describing: type))
            XCTAssertNotNil(result.refusal, String(describing: type))
        }
        for type in ["msdos", "exfat"] {
            let result = AppleDoubleSweeper(fileSystemType: { _ in type }).plan(volumeRoot: iPod.root, scope: nil)
            XCTAssertEqual(result.candidates, ["Music/A/._x.mp3"], type)
            XCTAssertNil(result.refusal, type)
        }
    }

    func testUnreadableTwinIsLeftAlone() throws {
        let twin = iPod.root.appendingPathComponent("Music/A/._x.mp3")
        try addTwin("Music/A/._x.mp3")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: twin.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: twin.path) }
        let result = plan()
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, ["not AppleDouble": 1])
    }

    func testUnreadableFolderIsSkippedWithoutThrowing() throws {
        try addTwin("Music/Locked/._x.mp3")
        try addTwin("Music/Open/._y.mp3")
        let locked = iPod.root.appendingPathComponent("Music/Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(plan().candidates, ["Music/Open/._y.mp3"])
    }

    // MARK: Scope

    func testScopedPlanIsNotRecursive() throws {
        try addTwin("\(album)/._01.m4a")
        try addTwin("\(album)/Disc 2/._01.m4a")
        try addTwin("Music/Other/._01.m4a")
        let result = plan(scope: [album])
        XCTAssertEqual(result.candidates, ["\(album)/._01.m4a"])
    }

    func testScopeListsEachFolderOnce() throws {
        try addTwin("\(album)/._01.m4a")
        try addTwin("Music/Other/._02.m4a")
        let result = plan(scope: [album, "Music/Other", album])
        XCTAssertEqual(result.candidates, ["\(album)/._01.m4a", "Music/Other/._02.m4a"])
        XCTAssertEqual(result.sizeHistogram, [4096: 2])
    }

    func testScopeOutsideTheVolumeIsIgnored() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDoubleSweeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FakeIPod.appleDoubleBytes().write(to: outside.appendingPathComponent("._x.mp3"))
        let result = sweeper.plan(volumeRoot: iPod.root, scope: [outside],
                                               mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
        XCTAssertEqual(result.candidates, [])
    }

    func testMissingScopeFolderGivesEmptyPlan() {
        XCTAssertEqual(plan(scope: ["Music/Nowhere"]).candidates, [])
    }

    func testWholeVolumePlanFindsTwinsInPlaylistsAndArtwork() throws {
        try addTwin("Playlists/._Pl.m3u8")
        try addTwin("Artwork/People/._Radiohead.jpg")
        try addTwin("Artwork/Covers/._abc.jpg")
        try addTwin("._Notes.pdf")
        let result = plan()
        XCTAssertEqual(result.candidates, ["._Notes.pdf", "Artwork/Covers/._abc.jpg",
                                           "Artwork/People/._Radiohead.jpg", "Playlists/._Pl.m3u8"])
    }

    // MARK: Plan and apply

    func testOperationsAreOneAppleDoubleDeletePerCandidateSortedByPath() throws {
        try addTwin("Music/B/._2.mp3")
        try addTwin("Music/A/._1.mp3")
        let ops = plan().operations
        XCTAssertEqual(ops.count, 2)
        let paths: [String] = ops.compactMap {
            guard case let .delete(path, reason) = $0, reason == .appleDouble else { return nil }
            return path
        }
        XCTAssertEqual(paths, ["Music/A/._1.mp3", "Music/B/._2.mp3"])
    }

    func testPlanDeletesNothing() throws {
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a"], appleDoubleTwins: true)
        try addTwin("Notes/._todo.txt")
        let files = allFiles()
        let result = plan()
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertEqual(allFiles(), files)
    }

    func testMissingVolumeGivesEmptyPlan() {
        let result = sweeper.plan(volumeRoot: iPod.root.appendingPathComponent("gone"), scope: nil,
                                               mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.leftAlone, [:])
    }

    func testPlanThenExecutorRemovesExactlyTheCandidates() throws {
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a", "02 - Norway.m4a"], appleDoubleTwins: true)
        try addTwin("Playlists/._Pl.m3u8")
        try addTwin("Notes/._todo.txt")                                       // not media: stays
        try addTwin("Music/A/._big.mp3", FakeIPod.appleDoubleBytes(size: 129 * 1024)) // too large: stays
        try addTwin(".rockbox/themes/._x.jpg")                               // player's: stays
        before = try iPod.manifest()

        let result = plan()
        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDoubleSweeperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let journal = DeviceWriteJournal(profileID: UUID(), directory: journalDir)
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: "V",
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          volumeUUID: { _ in "V" }, freeSpace: { _ in 1 << 40 },
                                          rootMustBeMountPoint: false) // the FakeIPod is a temp folder
        let filesBefore = Set(allFiles())
        let session = UUID()
        let outcomes = executor.apply(result.operations, sessionID: session)

        XCTAssertEqual(outcomes, Array(repeating: .deleted, count: result.candidates.count))
        XCTAssertEqual(Set(allFiles()), filesBefore.subtracting(result.candidates))
        for path in ["\(album)/01 - Zebra.m4a", "\(album)/02 - Norway.m4a", "\(album)/cover.jpg",
                     "Playlists/Pl.m3u8", "Notes/._todo.txt", "Music/A/._big.mp3", ".rockbox/themes/._x.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: iPod.root.appendingPathComponent(path).path), path)
        }
        // Every deleted twin was kept on the Mac first.
        let records = journal.records(sessionID: session).filter { $0.kind == .deleted }
        XCTAssertEqual(records.map(\.relativePath).sorted(), result.candidates)
        for record in records {
            let backup = try XCTUnwrap(record.backupFile)
            XCTAssertEqual(try Data(contentsOf: journal.folder.appendingPathComponent(backup)),
                           FakeIPod.appleDoubleBytes())
        }
        // Planning again finds nothing more to do.
        XCTAssertEqual(plan().candidates, [])
    }

    func testTwinChangedAfterPlanIsRefusedAtApply() throws {
        try addTwin("Music/A/._1.mp3")
        try addTwin("Music/A/._2.mp3")
        try addTwin("Music/A/._3.mp3")
        let result = plan()
        XCTAssertEqual(result.candidates.count, 3)
        // Between plan and apply: one becomes real audio, one becomes a folder.
        let real = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64)
        try real.write(to: iPod.root.appendingPathComponent("Music/A/._1.mp3"))
        try FileManager.default.removeItem(at: iPod.root.appendingPathComponent("Music/A/._2.mp3"))
        try FileManager.default.createDirectory(at: iPod.root.appendingPathComponent("Music/A/._2.mp3"),
                                                withIntermediateDirectories: false)

        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDoubleSweeperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: nil,
                                          policy: DeviceWritePolicy(musicSubpath: "Music"),
                                          journal: DeviceWriteJournal(profileID: UUID(), directory: journalDir),
                                          freeSpace: { _ in 1 << 40 },
                                          rootMustBeMountPoint: false) // the FakeIPod is a temp folder
        XCTAssertEqual(executor.apply(result.operations, sessionID: UUID()),
                       [.refusedNotAppleDouble, .refusedNotAppleDouble, .deleted])
        XCTAssertEqual(try Data(contentsOf: iPod.root.appendingPathComponent("Music/A/._1.mp3")), real)
    }
}
