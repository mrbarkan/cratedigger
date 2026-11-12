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
