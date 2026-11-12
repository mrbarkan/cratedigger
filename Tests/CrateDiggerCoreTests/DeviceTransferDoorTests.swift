import Darwin
import XCTest
@testable import CrateDiggerCore

/// The door a transfer writes through: audio copies, Replace deletions and
/// covers, each checked by the policy and written by the executor. Every
/// test runs on a FakeIPod and ends proving the player's files untouched.
final class DeviceTransferDoorTests: XCTestCase {
    private var iPod: FakeIPod!
    private var before: [String: String] = [:]
    private var mac: URL!
    private var door: DeviceTransferDoor!
    private let album = "Music/Classics/Beach House/2010 Teen Dream"

    override func setUpWithError() throws {
        iPod = try FakeIPod()
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a"], cover: false)
        before = try iPod.manifest()
        mac = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferDoorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        door = DeviceTransferDoor.onTempFolder(iPod.root, musicSubpath: "Music",
                                               journalDirectory: mac.appendingPathComponent("journal"))
    }

    override func tearDownWithError() throws {
        iPod.assertPlayerStateUntouched(since: before)
        try? FileManager.default.removeItem(at: mac)
        iPod = nil
    }

    // MARK: Helpers

    private func url(_ relative: String) -> URL { iPod.root.appendingPathComponent(relative) }

    private func macFile(_ name: String, _ data: Data = Data("audio bytes".utf8)) throws -> URL {
        let file = mac.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func modified(_ relative: String) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url(relative).path)[.modificationDate] as? Date)
    }

    private func attributeCount(_ url: URL) -> Int {
        max(0, listxattr(url.path, nil, 0, XATTR_NOFOLLOW))
    }

    // MARK: Audio

    func testCopyAudioLandsWithoutAttributesOrTwin() throws {
        let source = try macFile("new.m4a")
        XCTAssertEqual(setxattr(source.path, "com.example.test", "v", 1, 0, XATTR_NOFOLLOW), 0)
        let destination = url("\(album)/02 - Silver Soul.m4a")

        try door.copyAudio(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("audio bytes".utf8))
        XCTAssertEqual(attributeCount(destination), 0, "data only: nothing for macOS to keep in a ._ twin")
        XCTAssertFalse(iPod.allRelativePaths(under: album).contains { $0.contains("/._") })
        XCTAssertFalse(iPod.allRelativePaths(under: album).contains { $0.hasSuffix(DeviceFileIO.tempSuffix) })
        XCTAssertEqual(door.journal.records(sessionID: door.sessionID).filter { $0.kind == .created }.map(\.relativePath),
                       ["\(album)/02 - Silver Soul.m4a"])
    }

    func testCopyAudioIntoRockboxIsRefusedAndWritesNothing() throws {
        let source = try macFile("x.mp3")
        XCTAssertThrowsError(try door.copyAudio(from: source, to: url(".rockbox/x.mp3"))) { error in
            guard case DeviceTransferDoorError.forbidden = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.hasPrefix("CrateDigger does not write there: "))
        }
        XCTAssertThrowsError(try door.copyAudio(from: source, to: url(".ROCKBOX./themes/x.mp3")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(".rockbox/x.mp3").path))
        XCTAssertEqual(door.journal.records, [])
    }

    func testCopyAudioOutsideVolumeIsRefused() throws {
        let source = try macFile("x.mp3")
        let elsewhere = mac.appendingPathComponent("Music/x.mp3")
        XCTAssertThrowsError(try door.copyAudio(from: source, to: elsewhere)) { error in
            guard case DeviceTransferDoorError.outsideVolume = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    func testCopyAudioRefusesAFileThatIsAlreadyThere() throws {
        let source = try macFile("other.m4a", Data("another master".utf8))
        XCTAssertThrowsError(try door.copyAudio(from: source, to: url("\(album)/01 - Zebra.m4a"))) { error in
            XCTAssertEqual(error as? DeviceTransferDoorError, .appeared)
        }
        XCTAssertNotEqual(try Data(contentsOf: url("\(album)/01 - Zebra.m4a")), Data("another master".utf8))
    }

    func testCopyAudioOverwritesOnlyWhenTheUserChoseReplace() throws {
        let source = try macFile("other.m4a", Data("another master".utf8))
        try door.copyAudio(from: source, to: url("\(album)/01 - Zebra.m4a"), overwrites: true)
        XCTAssertEqual(try Data(contentsOf: url("\(album)/01 - Zebra.m4a")), Data("another master".utf8))
        let record = try XCTUnwrap(door.journal.records(sessionID: door.sessionID).last)
        XCTAssertEqual(record.kind, .replaced)
        XCTAssertNil(record.backupFile, "Replace keeps no copy of the old audio, as a Replace delete keeps none")
    }

    func testConversionDestinationsAllChecked() throws {
        let good = url("\(album)/02 - Silver Soul.mp3")
        XCTAssertNoThrow(try door.checkConversionDestinations([good]))
        XCTAssertThrowsError(try door.checkConversionDestinations([good, url("iPod_Control/Music/x.mp3")]))
        XCTAssertThrowsError(try door.checkConversionDestinations([good, url("Music/R.E.M./x.mp3")])) { error in
            XCTAssertEqual(error as? DeviceTransferDoorError, .forbidden("a name ending in a dot or a space"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path), "a check writes nothing")
    }

    func testFinishConvertedFileRemovesTwin() throws {
        // A converted file is staged on the Mac, where a write may leave
        // attributes on it; the copy to the device carries its data only.
        let staged = try macFile("converted.mp3", Data("encoded".utf8))
        XCTAssertEqual(setxattr(staged.path, "com.apple.quarantine", "q", 1, 0, XATTR_NOFOLLOW), 0)
        let destination = url("\(album)/02 - Silver Soul.mp3")

        try door.copyAudio(from: staged, to: destination)

        XCTAssertEqual(attributeCount(destination), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("\(album)/._02 - Silver Soul.mp3").path))
    }

    func testRemoveReplacedAudioRefusesNonAudioAndDeniedTrees() throws {
        try iPod.addFile("\(album)/notes.txt", Data("mine".utf8))
        XCTAssertThrowsError(try door.removeReplacedAudio(at: url("\(album)/notes.txt")))
        XCTAssertThrowsError(try door.removeReplacedAudio(at: url(".rockbox/library/user/playback.log")))
        XCTAssertThrowsError(try door.removeReplacedAudio(at: url("iPod_Control/iTunes/iTunesDB")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("\(album)/notes.txt").path))

        XCTAssertTrue(try door.removeReplacedAudio(at: url("\(album)/01 - Zebra.m4a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("\(album)/01 - Zebra.m4a").path))
        XCTAssertFalse(try door.removeReplacedAudio(at: url("\(album)/01 - Zebra.m4a")), "already gone")
    }

    // MARK: Covers

    func testWriteCoverSkipsIdenticalBytes() throws {
        let cover = url("\(album)/cover.jpg")
        XCTAssertTrue(try door.writeCover(Data("jpeg".utf8), to: cover))
        let date = try modified("\(album)/cover.jpg")

        XCTAssertFalse(try door.writeCover(Data("jpeg".utf8), to: cover))

        XCTAssertEqual(try modified("\(album)/cover.jpg"), date)
    }

    func testWriteCoverReplacesDifferentBytes() throws {
        try iPod.addFile("\(album)/cover.jpg", Data("theirs".utf8))
        XCTAssertTrue(try door.writeCover(Data("ours".utf8), to: url("\(album)/cover.jpg")))
        XCTAssertEqual(try Data(contentsOf: url("\(album)/cover.jpg")), Data("ours".utf8))
        let record = try XCTUnwrap(door.journal.records(sessionID: door.sessionID).last)
        XCTAssertNotNil(record.backupFile, "the cover it replaced is kept on the Mac")
    }

    func testWriteCoverRefusesAnotherName() throws {
        XCTAssertThrowsError(try door.writeCover(Data("x".utf8), to: url("\(album)/folder.jpg")))
    }

    // MARK: FIX ART: only adds

    func testWriteCoverWithoutReplacingLeavesAnyCoverThere() throws {
        try iPod.addFile("\(album)/cover.jpg", Data("theirs".utf8))
        XCTAssertThrowsError(try door.writeCover(Data("ours".utf8), to: url("\(album)/cover.jpg"),
                                                 replacesExisting: false)) { error in
            XCTAssertEqual(error as? DeviceTransferDoorError, .appeared)
        }
        XCTAssertEqual(try Data(contentsOf: url("\(album)/cover.jpg")), Data("theirs".utf8))
        XCTAssertEqual(door.journal.records(sessionID: door.sessionID).filter { $0.kind != .tempIntent }, [])
    }

    func testWriteCoverWithoutReplacingKeepsEvenCrateDiggersOwnCover() throws {
        let cover = url("\(album)/cover.jpg")
        XCTAssertTrue(try door.writeCover(Data("first".utf8), to: cover))
        XCTAssertThrowsError(try door.writeCover(Data("second".utf8), to: cover, replacesExisting: false))
        XCTAssertEqual(try Data(contentsOf: cover), Data("first".utf8))
        XCTAssertFalse(try door.writeCover(Data("first".utf8), to: cover, replacesExisting: false),
                       "the same bytes are the cover already done")
    }

    func testWriteCoverWithoutReplacingAddsWhereThereIsNone() throws {
        XCTAssertTrue(try door.writeCover(Data("new".utf8), to: url("\(album)/cover.jpg"), replacesExisting: false))
        XCTAssertEqual(try Data(contentsOf: url("\(album)/cover.jpg")), Data("new".utf8))
        XCTAssertNil(door.journal.backupFolderIfUsed(sessionID: door.sessionID), "nothing was replaced")
    }

    func testReplacingACoverLeavesASessionBackupToShow() throws {
        try iPod.addFile("\(album)/cover.jpg", Data("theirs".utf8))
        XCTAssertNil(door.journal.backupFolderIfUsed(sessionID: door.sessionID))
        XCTAssertTrue(try door.writeCover(Data("ours".utf8), to: url("\(album)/cover.jpg")))
        let folder = try XCTUnwrap(door.journal.backupFolderIfUsed(sessionID: door.sessionID))
        XCTAssertEqual(folder, door.journal.backupFolder(sessionID: door.sessionID))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("\(album)/cover.jpg")), Data("theirs".utf8))
        XCTAssertNil(door.journal.backupFolderIfUsed(sessionID: UUID()), "another session kept nothing")
    }

    /// FIX ART end to end on the fake iPod: the plan keeps every folder with
    /// a cover (any case) out, and the writer, through the door without
    /// replacing, adds covers only to the rest.
    func testFixArtAddsCoversOnlyWhereThereAreNone() throws {
        let bare = try iPod.addAlbum(category: "Classics", artist: "Low", folder: "2001 Things We Lost",
                                     tracks: ["01 - Sunflower.m4a"], cover: false)
        let covered = try iPod.addAlbum(category: "Classics", artist: "Yo La Tengo", folder: "1997 I Can Hear",
                                        tracks: ["01 - Return.m4a"], cover: true)
        let upper = try iPod.addAlbum(category: "Classics", artist: "Slowdive", folder: "1993 Souvlaki",
                                      tracks: ["01 - Alison.m4a"], cover: false)
        try iPod.addFile("Music/Classics/Slowdive/1993 Souvlaki/Cover.JPG", Data("upper".utf8))
        let coveredBytes = try Data(contentsOf: covered.appendingPathComponent("cover.jpg"))
        let teenDream = url(album)

        let plan = FolderCoverArtWriter.fixArtPlan(
            representatives: FolderCoverArtWriter.representativeAudioFiles(under: url("Music")),
            hasCover: { FolderCoverArtWriter.hasCover(in: $0) })
        XCTAssertEqual(Set(plan.needsCover.keys.map(\.standardizedFileURL)),
                       Set([bare, teenDream].map(\.standardizedFileURL)))
        XCTAssertEqual(plan.alreadyCovered.map(\.standardizedFileURL),
                       [upper, covered].map(\.standardizedFileURL).sorted { $0.path < $1.path })

        let asset = ArtworkAsset(source: .embedded, hash: "h", dimensions: ArtworkDimensions(width: 2, height: 2),
                                 data: Data("art".utf8))
        let writer = FolderCoverArtWriter(preparer: PassThroughPreparer(),
                                          writeData: { try self.door.writeCover($0, to: $1, replacesExisting: false) })
        let counts = writer.writeCounting(Dictionary(uniqueKeysWithValues: plan.needsCover.keys.map { ($0, asset) }))

        XCTAssertEqual(counts, FolderCoverArtWriter.WriteCounts(written: 2))
        XCTAssertEqual(try Data(contentsOf: covered.appendingPathComponent("cover.jpg")), coveredBytes)
        XCTAssertEqual(try Data(contentsOf: upper.appendingPathComponent("Cover.JPG")), Data("upper".utf8))
        XCTAssertEqual(try Data(contentsOf: bare.appendingPathComponent("cover.jpg")), Data("art".utf8))
        XCTAssertNil(door.journal.backupFolderIfUsed(sessionID: door.sessionID), "FIX ART replaced nothing")

        let text = FolderCoverArtWriter.FixArtText.confirmation(plan, deviceName: "IPOD")
        XCTAssertEqual(text.title, "Add covers to 2 album folders?")
        XCTAssertTrue(text.message.contains("2 album folders on IPOD have no cover.jpg"), text.message)
        XCTAssertTrue(text.message.contains("2 album folders already have one and are left as they are"), text.message)
        let result = FolderCoverArtWriter.FixArtText.result(counts, noArtwork: 1, plan: plan, deviceName: "IPOD")
        XCTAssertEqual(result.message, "Added a cover.jpg to 2 album folders on IPOD. 2 album folders already had one and were left as they were. 1 album folder has no artwork in its tracks to copy out.")
    }
}

/// Hands the artwork's bytes through untouched, so a test can see exactly what landed.
private struct PassThroughPreparer: ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset { asset }
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile, maxDimension: Int?) throws -> ArtworkAsset {
        asset
    }
}

extension DeviceTransferDoor {
    /// A door on a temp folder standing in for a device: the executor's
    /// mount-point check is off, the volume reports a fixed UUID, and there
    /// is always room. Every other check applies.
    static func onTempFolder(_ root: URL, musicSubpath: String, journalDirectory: URL,
                             sessionID: UUID = UUID()) -> DeviceTransferDoor {
        let executor = DeviceFileExecutor(
            volumeRoot: root, expectedVolumeUUID: "TEST-VOLUME",
            policy: DeviceWritePolicy(musicSubpath: musicSubpath),
            journal: DeviceWriteJournal(profileID: UUID(), directory: journalDirectory),
            volumeUUID: { _ in "TEST-VOLUME" }, freeSpace: { _ in 1 << 40 },
            rootMustBeMountPoint: false)
        return DeviceTransferDoor(executor: executor, sessionID: sessionID)
    }
}
