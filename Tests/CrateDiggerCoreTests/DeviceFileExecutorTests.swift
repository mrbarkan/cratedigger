import XCTest
@testable import CrateDiggerCore

/// Every test builds a FakeIPod, takes its manifest first and ends by
/// proving the player's own files were not touched.
final class DeviceFileExecutorTests: XCTestCase {
    private var iPod: FakeIPod!
    private var before: [String: String] = [:]
    private var journalDir: URL!
    private var macDir: URL!
    private let session = UUID()
    private let profileID = UUID()
    private let volume = "VOLUME-UUID-1"

    override func setUpWithError() throws {
        iPod = try FakeIPod()
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a"], cover: false)
        before = try iPod.manifest()
        journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceFileExecutorTests-\(UUID().uuidString)", isDirectory: true)
        macDir = journalDir.appendingPathComponent("mac", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        iPod.assertPlayerStateUntouched(since: before)
        // A test may have made a folder read-only to break the journal.
        if let walker = FileManager.default.enumerator(atPath: journalDir.path) {
            for case let relative as String in walker {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: journalDir.appendingPathComponent(relative).path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalDir.path)
        try? FileManager.default.removeItem(at: journalDir)
        iPod = nil
    }

    // MARK: Helpers

    private let album = "Music/Classics/Beach House/2010 Teen Dream"
    private var coverPath: String { "\(album)/cover.jpg" }

    private func journal(_ directory: URL? = nil) -> DeviceWriteJournal {
        DeviceWriteJournal(profileID: profileID, directory: directory ?? journalDir)
    }

    /// The FakeIPod is a temp folder, not a mount point: tests opt out of that one check.
    private func executor(journal: DeviceWriteJournal? = nil, uuid: String? = nil, expected: String?? = nil,
                          free: Int64? = 1 << 40,
                          policy: DeviceWritePolicy = DeviceWritePolicy(musicSubpath: "Music")) -> DeviceFileExecutor {
        let reported = uuid ?? volume
        return DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: expected ?? volume,
                                  policy: policy, journal: journal ?? self.journal(),
                                  volumeUUID: { _ in reported }, freeSpace: { _ in free },
                                  rootMustBeMountPoint: false)
    }

    private func url(_ relative: String) -> URL { iPod.root.appendingPathComponent(relative) }

    private func bytes(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    private func modified(_ relative: String) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url(relative).path)[.modificationDate] as? Date)
    }

    private func macFile(_ name: String, _ data: Data) throws -> URL {
        let file = macDir.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func tempFilesOnDevice() -> [String] {
        let walker = FileManager.default.enumerator(atPath: iPod.root.path)
        return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(DeviceFileIO.tempSuffix) }
    }

    private func writeCover(_ data: Data, replacesForeign: Bool = false,
                            with executor: DeviceFileExecutor? = nil) -> DeviceFileOutcome {
        (executor ?? self.executor()).apply([.write(relativePath: coverPath, role: .cover, contents: .data(data),
                                                    replacesForeign: replacesForeign)],
                                            sessionID: session)[0]
    }

    // MARK: Writes

    func testWriteCreatesFileAndJournalRecord() throws {
        let j = journal()
        XCTAssertEqual(writeCover(Data("cover v1".utf8), with: executor(journal: j)), .written)
        XCTAssertEqual(try bytes(coverPath), Data("cover v1".utf8))
        let record = try XCTUnwrap(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
        XCTAssertEqual(record.kind, .created)
        XCTAssertEqual(record.role, "cover")
        XCTAssertEqual(record.size, 8)
        XCTAssertEqual(record.sha256, try DeviceFileIO.sha256(of: url(coverPath)))
        XCTAssertEqual(record.volumeUUID, volume)
        XCTAssertEqual(record.sessionID, session)
        XCTAssertNil(record.backupFile)
        XCTAssertEqual(j.records(sessionID: session).filter { $0.kind == .tempIntent }.map(\.relativePath),
                       [coverPath + ".cdtmp"])
        XCTAssertEqual(tempFilesOnDevice(), [])
    }

    func testIdenticalBytesAreUnchangedAndDateIsKept() throws {
        XCTAssertEqual(writeCover(Data("cover".utf8)), .written)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url(coverPath).path)
        XCTAssertEqual(writeCover(Data("cover".utf8)), .unchanged)
        XCTAssertEqual(try modified(coverPath), old)
    }

    func testForeignFileIsRefused() throws {
        try iPod.addFile(coverPath, Data("the owner's cover".utf8))
        XCTAssertEqual(writeCover(Data("ours".utf8)), .refusedForeign)
        XCTAssertEqual(try bytes(coverPath), Data("the owner's cover".utf8))
    }

    func testOwnedFileIsReplacedAndBackedUp() throws {
        let j = journal()
        XCTAssertEqual(writeCover(Data("v1".utf8), with: executor(journal: j)), .written)
        XCTAssertEqual(writeCover(Data("v2".utf8), with: executor(journal: j)), .written)
        XCTAssertEqual(try bytes(coverPath), Data("v2".utf8))
        let record = try XCTUnwrap(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
        XCTAssertEqual(record.kind, .replaced)
        let backup = try XCTUnwrap(record.backupFile)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(backup)), Data("v1".utf8))
    }

    func testOwnedFileEditedSinceReadsAsForeign() throws {
        XCTAssertEqual(writeCover(Data("ours".utf8)), .written)
        try iPod.addFile(coverPath, Data("edited by hand".utf8))
        XCTAssertEqual(writeCover(Data("ours again".utf8)), .refusedForeign)
        XCTAssertEqual(try bytes(coverPath), Data("edited by hand".utf8))
    }

    func testFileRemovedByOwnerIsRecreated() throws {
        let j = journal()
        XCTAssertEqual(writeCover(Data("ours".utf8), with: executor(journal: j)), .written)
        try FileManager.default.removeItem(at: url(coverPath))
        XCTAssertEqual(writeCover(Data("ours".utf8), with: executor(journal: j)), .written)
        XCTAssertEqual(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath))?.kind, .created)
    }

    func testRenameWithoutJournalRecordReadsAsForeignNextTime() throws {
        // A journal folder nobody can write into: every append throws.
        let locked = journalDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let broken = journal(locked)

        let first = writeCover(Data("v1".utf8), with: executor(journal: broken))
        guard case .failed(let message) = first else { return XCTFail("expected failed, got \(first)") }
        XCTAssertTrue(message.contains("could not be recorded"), message)
        XCTAssertEqual(try bytes(coverPath), Data("v1".utf8))

        XCTAssertEqual(writeCover(Data("v2".utf8), with: executor(journal: journal())), .refusedForeign)
        XCTAssertEqual(try bytes(coverPath), Data("v1".utf8))
    }

    func testCoverMayReplaceForeignAndBacksItUp() throws {
        try iPod.addFile(coverPath, Data("the owner's cover".utf8))
        let j = journal()
        XCTAssertEqual(writeCover(Data("ours".utf8), replacesForeign: true, with: executor(journal: j)), .written)
        XCTAssertEqual(try bytes(coverPath), Data("ours".utf8))
        let record = try XCTUnwrap(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
        XCTAssertEqual(record.kind, .replaced)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(try XCTUnwrap(record.backupFile))),
                       Data("the owner's cover".utf8))
    }

    func testReplacesForeignIgnoredForOtherRoles() throws {
        let track = "\(album)/01 - Zebra.m4a"
        let original = try bytes(track)
        let source = try macFile("zebra.m4a", Data("a different master".utf8))
        let outcome = executor().apply([.write(relativePath: track, role: .audio, contents: .file(source),
                                               replacesForeign: true)], sessionID: session)
        XCTAssertEqual(outcome, [.refusedForeign])
        XCTAssertEqual(try bytes(track), original)
    }

    func testPolicyRefusalDoesNoIO() throws {
        let j = journal()
        let outcome = executor(journal: j).apply(
            [.write(relativePath: ".rockbox/x.mp3", role: .audio, contents: .data(Data("x".utf8))),
             .write(relativePath: "Music/New Folder/x.dat", role: .audio, contents: .data(Data("x".utf8)))],
            sessionID: session)
        guard case .refusedPolicy = outcome[0], case .refusedPolicy = outcome[1] else {
            return XCTFail("expected policy refusals, got \(outcome)")
        }
        XCTAssertEqual(j.records, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("Music/New Folder").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.folder.path))
    }

    func testSymlinkOutOfMusicFolderIsRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: url("Music/link").path, withDestinationPath: "../.rockbox")
        try FileManager.default.createSymbolicLink(atPath: url("Music/away").path,
                                                   withDestinationPath: macDir.path)
        let outcome = executor().apply(
            [.write(relativePath: "Music/link/x.mp3", role: .audio, contents: .data(Data("x".utf8))),
             .write(relativePath: "Music/link/sub/x.mp3", role: .audio, contents: .data(Data("x".utf8))),
             .write(relativePath: "Music/away/x.mp3", role: .audio, contents: .data(Data("x".utf8))),
             .delete(relativePath: "Music/link/config.cfg", reason: .userReplace),
             .delete(relativePath: "Music/link/._config.cfg", reason: .appleDouble)],
            sessionID: session)
        for result in outcome {
            guard case .refusedPolicy = result else { return XCTFail("expected policy refusals, got \(outcome)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: macDir.path), [])
    }

    func testTargetThatIsASymlinkIsForeign() throws {
        try FileManager.default.createSymbolicLink(atPath: url(coverPath).path,
                                                   withDestinationPath: "../../../../.rockbox/config.cfg")
        XCTAssertEqual(writeCover(Data("ours".utf8)), .refusedForeign)
        let deleted = executor().apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger)],
                                       sessionID: session)
        XCTAssertEqual(deleted, [.refusedForeign])
    }

    func testVolumeChangedBetweenPlanAndApplyRefusesEverything() throws {
        let j = journal()
        let ops: [DeviceFileOperation] = [
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("x".utf8))),
            .delete(relativePath: "\(album)/01 - Zebra.m4a", reason: .userReplace),
        ]
        XCTAssertEqual(executor(journal: j, uuid: "ANOTHER-IPOD").apply(ops, sessionID: session),
                       [.refusedWrongVolume, .refusedWrongVolume])
        let noUUID = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: volume,
                                        policy: DeviceWritePolicy(musicSubpath: "Music"), journal: j,
                                        volumeUUID: { _ in nil }, freeSpace: { _ in nil },
                                        rootMustBeMountPoint: false)
        XCTAssertEqual(noUUID.apply(ops, sessionID: session), [.refusedWrongVolume, .refusedWrongVolume])
        XCTAssertEqual(j.records, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("\(album)/01 - Zebra.m4a").path))
    }

    func testRootVanishedMidApplyFailsRemainingOps() throws {
        // The device's files, kept to restore the root for the teardown check.
        let saved = journalDir.appendingPathComponent("saved-root", isDirectory: true)
        let ops: [DeviceFileOperation] = [
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("x".utf8))),
            .write(relativePath: "\(album)/02 - Silver Soul.m4a", role: .audio, contents: .data(Data("y".utf8))),
            .delete(relativePath: "\(album)/01 - Zebra.m4a", reason: .userReplace),
        ]
        var pulled = false
        let outcome = executor().apply(ops, sessionID: session) { done, _ in
            guard done == 1, !pulled else { return }
            pulled = true
            try? FileManager.default.moveItem(at: self.iPod.root, to: saved) // the cable is pulled
        }
        XCTAssertEqual(outcome[0], .written)
        for later in outcome.dropFirst() {
            switch later {
            case .refusedWrongVolume, .failed: break
            default: XCTFail("expected refusedWrongVolume or failed, got \(later)")
            }
        }
        try FileManager.default.moveItem(at: saved, to: iPod.root) // plugged back in
        XCTAssertEqual(tempFilesOnDevice(), [])
    }

    func testPlainFolderRootIsRefusedWhenADeviceWasExpected() throws {
        // The public initialiser insists on a mount point: a folder on the Mac's disk is not an iPod.
        let ops: [DeviceFileOperation] = [
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("x".utf8))),
            .delete(relativePath: "\(album)/01 - Zebra.m4a", reason: .userReplace),
        ]
        let withUUID = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: volume,
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal(),
                                          volumeUUID: { _ in self.volume }, freeSpace: { _ in 1 << 40 })
        XCTAssertEqual(withUUID.apply(ops, sessionID: session), [.refusedWrongVolume, .refusedWrongVolume])
        let withoutUUID = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: nil,
                                             policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal(),
                                             freeSpace: { _ in 1 << 40 })
        XCTAssertEqual(withoutUUID.apply(ops, sessionID: session), [.refusedWrongVolume, .refusedWrongVolume])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("\(album)/01 - Zebra.m4a").path))
        // The real root of the Mac's disk is a mount point; a folder in the temp dir is not.
        XCTAssertTrue(DeviceFileExecutor.isMountPoint(URL(fileURLWithPath: "/")))
        XCTAssertFalse(DeviceFileExecutor.isMountPoint(iPod.root))
    }

    func testSessionIsBoundToTheRootItCaptured() throws {
        // No expected UUID: the session still refuses a different folder put at the same path.
        let ex = executor(expected: .some(nil))
        let saved = journalDir.appendingPathComponent("saved-root", isDirectory: true)
        try FileManager.default.moveItem(at: iPod.root, to: saved)
        try FileManager.default.createDirectory(at: iPod.root.appendingPathComponent(album),
                                                withIntermediateDirectories: true)
        let outcome = ex.apply([.write(relativePath: coverPath, role: .cover, contents: .data(Data("x".utf8)))],
                               sessionID: session)
        XCTAssertEqual(outcome, [.refusedWrongVolume])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
        try FileManager.default.removeItem(at: iPod.root)
        try FileManager.default.moveItem(at: saved, to: iPod.root)
        XCTAssertEqual(ex.apply([.write(relativePath: coverPath, role: .cover, contents: .data(Data("x".utf8)))],
                                sessionID: session), [.written])
    }

    func testIdenticalFileFromAnotherVolumeIsNotOurs() throws {
        // The same profile wrote this exact file to another iPod: here it proves nothing.
        let j = journal()
        let otherIPod = executor(journal: j, uuid: "VOLUME-UUID-2", expected: "VOLUME-UUID-2")
        XCTAssertEqual(writeCover(Data("cover v1".utf8), with: otherIPod), .written)
        XCTAssertEqual(j.records.last?.volumeUUID, "VOLUME-UUID-2")

        let thisIPod = executor(journal: j)
        XCTAssertEqual(writeCover(Data("cover v2".utf8), with: thisIPod), .refusedForeign)
        XCTAssertEqual(thisIPod.apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger)],
                                      sessionID: session), [.refusedForeign])
        XCTAssertEqual(try bytes(coverPath), Data("cover v1".utf8))
    }

    func testTempIntentFromAnotherVolumeDoesNotLicenseCleanup() throws {
        let j = journal()
        try j.append([DeviceFileRecord(relativePath: coverPath + ".cdtmp", kind: .tempIntent, role: "temp",
                                       volumeUUID: "VOLUME-UUID-2", sessionID: UUID())])
        try iPod.addFile(coverPath + ".cdtmp", Data("someone else's".utf8))
        let outcome = executor(journal: j).apply(
            [.write(relativePath: coverPath, role: .cover, contents: .data(Data("cover".utf8))),
             .delete(relativePath: coverPath + ".cdtmp", reason: .staleTemp)], sessionID: session)
        XCTAssertEqual(outcome, [.refusedForeign, .refusedForeign])
        XCTAssertEqual(try bytes(coverPath + ".cdtmp"), Data("someone else's".utf8))
    }

    func testTempThePolicyRefusesRefusesTheWrite() throws {
        // known_artists.txt is the one file allowed under .rockbox; its temp is not.
        let j = journal()
        let knownArtists = DeviceWritePolicy(musicSubpath: "Music", enabledRoles: [.knownArtists, .temp])
        let outcome = executor(journal: j, policy: knownArtists).apply(
            [.write(relativePath: ".rockbox/library/user/known_artists.txt", role: .knownArtists,
                    contents: .data(Data("Guest\n".utf8)))], sessionID: session)
        guard case .refusedPolicy = outcome[0] else { return XCTFail("expected a policy refusal, got \(outcome)") }
        XCTAssertEqual(j.records, [])

        // A policy without the temp role cannot write anything, since every write lands through a temp.
        let noTemp = DeviceWritePolicy(musicSubpath: "Music", enabledRoles: [.cover])
        guard case .refusedPolicy = writeCover(Data("x".utf8), with: executor(policy: noTemp)) else {
            return XCTFail("expected a policy refusal")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
    }

    func testIdenticalBytesWinOverNoSpaceAndAForeignTemp() throws {
        XCTAssertEqual(writeCover(Data("cover".utf8)), .written)
        XCTAssertEqual(writeCover(Data("cover".utf8), with: executor(free: 1024)), .unchanged)
        try iPod.addFile(coverPath + ".cdtmp", Data("someone else's".utf8))
        XCTAssertEqual(writeCover(Data("cover".utf8)), .unchanged)
    }

    func testTargetOfAnotherSizeIsNotRead() throws {
        // An unreadable foreign file of a different size: refused as foreign without being opened.
        try iPod.addFile(coverPath, Data("the owner's, unreadable".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url(coverPath).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url(coverPath).path) }
        XCTAssertEqual(writeCover(Data("ours".utf8)), .refusedForeign)
    }

    func testAppleDoubleDeleteOfANonMediaTwinIsRefused() throws {
        try iPod.addFile("Notes/._todo.txt", FakeIPod.appleDoubleBytes())
        let outcome = executor().apply([.delete(relativePath: "Notes/._todo.txt", reason: .appleDouble)],
                                       sessionID: session)
        guard case .refusedPolicy = outcome[0] else { return XCTFail("expected a policy refusal, got \(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("Notes/._todo.txt").path))
    }

    func testNoSpaceRefusesBeforeWriting() throws {
        let j = journal()
        XCTAssertEqual(writeCover(Data("x".utf8), with: executor(journal: j, free: 1024 * 1024)), .refusedNoSpace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
        XCTAssertEqual(tempFilesOnDevice(), [])
        XCTAssertNil(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
    }

    func testFailedWriteLeavesNoTemp() throws {
        let missing = macDir.appendingPathComponent("gone.m4a")
        let outcome = executor().apply([.write(relativePath: "\(album)/02.m4a", role: .audio,
                                               contents: .file(missing))], sessionID: session)
        guard case .failed = outcome[0] else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(tempFilesOnDevice(), [])

        // A folder sitting where the file should go is not a file CrateDigger wrote.
        try FileManager.default.createDirectory(at: url("\(album)/03.m4a/inside"), withIntermediateDirectories: true)
        let blocked = executor().apply([.write(relativePath: "\(album)/03.m4a", role: .audio,
                                               contents: .data(Data("z".utf8)))], sessionID: session)
        XCTAssertEqual(blocked, [.refusedForeign])
        XCTAssertEqual(tempFilesOnDevice(), [])
    }

    func testStaleTempWithIntentIsRemoved() throws {
        // A session that crashed mid-write: it announced the temp, and left it.
        let j = journal()
        let crashed = UUID()
        try j.append([DeviceFileRecord(relativePath: coverPath + ".cdtmp", kind: .tempIntent, role: "temp",
                                       sessionID: crashed)])
        try iPod.addFile(coverPath + ".cdtmp", Data("half a cov".utf8))
        try iPod.addFile("\(album)/02.m4a.cdtmp", Data("half a track".utf8))
        try j.append([DeviceFileRecord(relativePath: "\(album)/02.m4a.cdtmp", kind: .tempIntent, role: "temp",
                                       sessionID: crashed)])

        let outcome = executor(journal: j).apply(
            [.write(relativePath: coverPath, role: .cover, contents: .data(Data("cover".utf8))),
             .delete(relativePath: "\(album)/02.m4a.cdtmp", reason: .staleTemp)],
            sessionID: session)
        XCTAssertEqual(outcome, [.written, .deleted])
        XCTAssertEqual(try bytes(coverPath), Data("cover".utf8))
        XCTAssertEqual(tempFilesOnDevice(), [])
    }

    func testStaleTempWithoutIntentIsForeign() throws {
        try iPod.addFile(coverPath + ".cdtmp", Data("someone else's".utf8))
        let outcome = executor().apply(
            [.write(relativePath: coverPath, role: .cover, contents: .data(Data("cover".utf8))),
             .delete(relativePath: coverPath + ".cdtmp", reason: .staleTemp)],
            sessionID: session)
        XCTAssertEqual(outcome, [.refusedForeign, .refusedForeign])
        XCTAssertEqual(try bytes(coverPath + ".cdtmp"), Data("someone else's".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
    }

    // MARK: Deletes

    func testOwnedDeleteNeedsMatchingHash() throws {
        XCTAssertEqual(writeCover(Data("ours".utf8)), .written)
        try iPod.addFile(coverPath, Data("changed".utf8))
        XCTAssertEqual(executor().apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger)],
                                        sessionID: session), [.refusedForeign])
        XCTAssertEqual(try bytes(coverPath), Data("changed".utf8))

        // A cover the journal never heard of.
        try iPod.addFile("Music/Other/cover.jpg", Data("x".utf8))
        let foreign = executor().apply([.delete(relativePath: "Music/Other/cover.jpg", reason: .ownedByCrateDigger)],
                                       sessionID: UUID())
        XCTAssertEqual(foreign, [.refusedForeign])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("Music/Other/cover.jpg").path))
    }

    func testOwnedDeleteBacksUpFirst() throws {
        let j = journal()
        XCTAssertEqual(writeCover(Data("ours".utf8), with: executor(journal: j)), .written)
        XCTAssertEqual(executor(journal: j).apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger)],
                                                  sessionID: session), [.deleted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(coverPath).path))
        let record = try XCTUnwrap(j.records.last)
        XCTAssertEqual(record.kind, .deleted)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(try XCTUnwrap(record.backupFile))),
                       Data("ours".utf8))
        XCTAssertNil(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
    }

    func testAppleDoubleDeleteReprovesAtApply() throws {
        let twin = "\(album)/._01 - Zebra.m4a"
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let plan: [DeviceFileOperation] = [.delete(relativePath: twin, reason: .appleDouble)]
        // Between plan and apply the file turns into real audio.
        try iPod.addFile(twin, Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64))
        XCTAssertEqual(executor().apply(plan, sessionID: session), [.refusedNotAppleDouble])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(twin).path))

        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let j = journal()
        XCTAssertEqual(executor(journal: j).apply(plan, sessionID: session), [.deleted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(twin).path))
        let backup = try XCTUnwrap(j.records.last?.backupFile)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(backup)), FakeIPod.appleDoubleBytes())
    }

    // MARK: The gap between a twin's backup and its removal (I4)

    /// Runs one AppleDouble delete of `twin` with `swap` run after the backup
    /// and before the removal.
    private func sweepTwin(_ twin: String, swap: @escaping (URL) throws -> Void) -> (DeviceFileOutcome, DeviceWriteJournal) {
        let j = journal()
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: volume,
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: j,
                                          volumeUUID: { [volume] _ in volume }, freeSpace: { _ in 1 << 40 },
                                          rootMustBeMountPoint: false,
                                          beforeAppleDoubleRemoval: { url in
                                              do { try swap(url) } catch { XCTFail("the swap failed: \(error)") }
                                          })
        let outcome = executor.apply([.delete(relativePath: twin, reason: .appleDouble)], sessionID: session)[0]
        return (outcome, j)
    }

    private let twin = "Music/Classics/Beach House/2010 Teen Dream/._01 - Zebra.m4a"

    func testTwinSwappedForAnotherFileAfterBackupIsNotDeleted() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        // Same size and the same header, but another file: a new inode.
        var replacement = FakeIPod.appleDoubleBytes()
        replacement[100] = 0x7f
        let (outcome, j) = sweepTwin(twin) { url in
            try FileManager.default.removeItem(at: url)
            try replacement.write(to: url)
        }
        XCTAssertEqual(outcome, .refusedNotAppleDouble)
        XCTAssertEqual(try bytes(twin), replacement)
        XCTAssertEqual(j.records.filter { $0.kind == .deleted }, [])
    }

    func testTwinRenamedOverAfterBackupIsNotDeleted() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let other = try iPod.addFile("Music/Classics/other.bin", FakeIPod.appleDoubleBytes()) // identical bytes
        let (outcome, _) = sweepTwin(twin) { url in
            XCTAssertEqual(Darwin.rename(other.path, url.path), 0)
        }
        XCTAssertEqual(outcome, .refusedNotAppleDouble, "same bytes, but not the file that was proven")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(twin).path))
    }

    func testTwinRewrittenInPlaceAfterBackupIsNotDeleted() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let audio = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 4096 - 12)
        let (outcome, _) = sweepTwin(twin) { url in
            // Same inode, same size, other bytes.
            let handle = try FileHandle(forUpdating: url)
            try handle.write(contentsOf: audio)
            try handle.close()
        }
        XCTAssertEqual(outcome, .refusedNotAppleDouble)
        XCTAssertEqual(try bytes(twin), audio)
    }

    func testTwinReplacedByAFolderOrSymlinkAfterBackupIsNotDeleted() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let target = try iPod.addFile("Music/Classics/elsewhere.bin", FakeIPod.appleDoubleBytes())
        let (outcome, _) = sweepTwin(twin) { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
        XCTAssertEqual(outcome, .refusedNotAppleDouble)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url(twin).path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testTwinRemovedAfterBackupIsAlreadyGone() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes())
        let (outcome, _) = sweepTwin(twin) { url in try FileManager.default.removeItem(at: url) }
        XCTAssertEqual(outcome, .alreadyGone)
    }

    func testUntouchedTwinIsBackedUpFromTheProvenBytesAndDeleted() throws {
        try iPod.addFile(twin, FakeIPod.appleDoubleBytes(size: 777))
        // The same folder sweepTwin's journal uses.
        let backup = journal().folder.appendingPathComponent("backups/\(session.uuidString)/\(twin)")
        var backupSeenBeforeRemoval: Data?
        let (outcome, j) = sweepTwin(twin) { _ in backupSeenBeforeRemoval = try Data(contentsOf: backup) }
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(twin).path))
        XCTAssertEqual(backupSeenBeforeRemoval, FakeIPod.appleDoubleBytes(size: 777))
        let record = try XCTUnwrap(j.records.last)
        XCTAssertEqual(record.kind, .deleted)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(try XCTUnwrap(record.backupFile))),
                       FakeIPod.appleDoubleBytes(size: 777))
    }

    func testDeleteOfMissingFileIsAlreadyGone() {
        XCTAssertEqual(executor().apply([.delete(relativePath: "\(album)/._gone.m4a", reason: .appleDouble),
                                         .delete(relativePath: "\(album)/gone.m4a", reason: .userReplace)],
                                        sessionID: session), [.alreadyGone, .alreadyGone])
    }

    func testUserReplaceDeletesAudioWithoutJournal() throws {
        let track = "\(album)/01 - Zebra.m4a"
        let j = journal()
        XCTAssertEqual(executor(journal: j).apply([.delete(relativePath: track, reason: .userReplace)],
                                                  sessionID: session), [.deleted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(track).path))
        XCTAssertEqual(j.records.last?.kind, .deleted)
        XCTAssertNil(j.records.last?.backupFile)
    }

    // MARK: Idempotence

    func testApplyingSamePlanTwiceChangesNothing() throws {
        let source = try macFile("silver.m4a", Data("silver soul".utf8))
        let ops: [DeviceFileOperation] = [
            .write(relativePath: "\(album)/02 - Silver Soul.m4a", role: .audio, contents: .file(source)),
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("cover".utf8))),
        ]
        let j = journal()
        XCTAssertEqual(executor(journal: j).apply(ops, sessionID: session), [.written, .written])
        let dates = try ops.map { try modified($0.relativePath) }
        let recordCount = j.records.filter { $0.kind != .tempIntent }.count

        XCTAssertEqual(executor(journal: j).apply(ops, sessionID: UUID()), [.unchanged, .unchanged])
        XCTAssertEqual(try ops.map { try modified($0.relativePath) }, dates)
        XCTAssertEqual(j.records.filter { $0.kind != .tempIntent }.count, recordCount)
    }

    func testAudioRecordHasNoHash() throws {
        let source = try macFile("silver.m4a", Data("silver soul".utf8))
        let j = journal()
        XCTAssertEqual(executor(journal: j).apply(
            [.write(relativePath: "\(album)/02 - Silver Soul.m4a", role: .audio, contents: .file(source))],
            sessionID: session), [.written])
        let record = try XCTUnwrap(j.records.last)
        XCTAssertEqual(record.role, "audio")
        XCTAssertNil(record.sha256)
        XCTAssertEqual(record.size, 11)
    }

    func testProgressCountsEveryOperation() {
        var calls: [Int] = []
        _ = executor().apply([.delete(relativePath: "\(album)/a.m4a", reason: .userReplace),
                              .delete(relativePath: "\(album)/b.m4a", reason: .userReplace)],
                             sessionID: session) { done, total in
            XCTAssertEqual(total, 2)
            calls.append(done)
        }
        XCTAssertEqual(calls, [1, 2])
    }
}
