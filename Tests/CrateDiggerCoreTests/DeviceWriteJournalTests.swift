import XCTest
@testable import CrateDiggerCore

final class DeviceWriteJournalTests: XCTestCase {
    private var dir: URL!
    private let profileID = UUID()
    private let session = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceWriteJournalTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func journal() -> DeviceWriteJournal {
        DeviceWriteJournal(profileID: profileID, directory: dir)
    }

    private func record(_ path: String, _ kind: DeviceFileRecord.Kind, session: UUID? = nil,
                        sha: String? = "abc") -> DeviceFileRecord {
        DeviceFileRecord(relativePath: path, kind: kind, role: "cover", size: 3, sha256: sha,
                         volumeUUID: "VOL", sessionID: session ?? self.session)
    }

    func testFolderIsPerProfile() {
        XCTAssertEqual(journal().folder.lastPathComponent, profileID.uuidString)
        XCTAssertEqual(journal().folder.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }

    func testAppendThenOwnedRecord() throws {
        let j = journal()
        try j.append([record("Music/A/cover.jpg", .created)])
        let owned = try XCTUnwrap(j.ownedRecord(forKey: "music/a/cover.jpg"))
        XCTAssertEqual(owned.relativePath, "Music/A/cover.jpg")
        XCTAssertEqual(owned.sha256, "abc")

        try j.append([record("Music/A/cover.jpg", .replaced)])
        XCTAssertEqual(j.ownedRecord(forKey: "music/a/cover.jpg")?.kind, .replaced)
    }

    func testOwnershipIsPerVolume() throws {
        let j = journal()
        try j.append([DeviceFileRecord(relativePath: "Music/A/cover.jpg", kind: .created, role: "cover", size: 3,
                                       sha256: "abc", volumeUUID: "IPOD-A", sessionID: session)])
        XCTAssertNotNil(j.ownedRecord(forKey: "music/a/cover.jpg", volumeUUID: "IPOD-A"))
        XCTAssertNil(j.ownedRecord(forKey: "music/a/cover.jpg", volumeUUID: "IPOD-B"))
        XCTAssertNotNil(j.ownedRecord(forKey: "music/a/cover.jpg")) // no UUID to tell them apart

        // A delete on the other iPod does not end ownership on this one.
        try j.append([DeviceFileRecord(relativePath: "Music/A/cover.jpg", kind: .deleted, role: "ownedByCrateDigger",
                                       volumeUUID: "IPOD-B", sessionID: session)])
        XCTAssertNotNil(j.ownedRecord(forKey: "music/a/cover.jpg", volumeUUID: "IPOD-A"))
        XCTAssertNil(j.ownedRecord(forKey: "music/a/cover.jpg", volumeUUID: "IPOD-B"))
    }

    func testDeletedAfterCreatedIsNotOwned() throws {
        let j = journal()
        try j.append([record("Music/A/cover.jpg", .created)])
        try j.append([record("Music/A/cover.jpg", .deleted, sha: nil)])
        XCTAssertNil(j.ownedRecord(forKey: "music/a/cover.jpg"))
    }

    func testKeyIsCaseAndNFCInsensitive() throws {
        let j = journal()
        try j.append([record("Music/Gda\u{0144}sk/cover.jpg", .created)])
        XCTAssertNotNil(j.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: "MUSIC/Gdan\u{0301}sk/COVER.JPG")))
        XCTAssertNotNil(j.ownedRecord(forKey: "MUSIC/Gdan\u{0301}sk/COVER.JPG"))
    }

    func testTempIntentIsNotOwnership() throws {
        let j = journal()
        try j.append([record("Music/A/cover.jpg.cdtmp", .tempIntent, sha: nil)])
        XCTAssertNil(j.ownedRecord(forKey: "music/a/cover.jpg.cdtmp"))

        // A temp intent after a write does not hide the write either.
        try j.append([record("Music/A/cover.jpg", .created), record("Music/A/cover.jpg", .tempIntent)])
        XCTAssertEqual(j.ownedRecord(forKey: "music/a/cover.jpg")?.kind, .created)
    }

    func testRecordsBySession() throws {
        let j = journal()
        let other = UUID()
        try j.append([record("Music/A/cover.jpg", .created), record("Music/B/cover.jpg", .created, session: other)])
        XCTAssertEqual(j.records(sessionID: session).map(\.relativePath), ["Music/A/cover.jpg"])
        XCTAssertEqual(j.records(sessionID: other).map(\.relativePath), ["Music/B/cover.jpg"])
    }

    func testBackUpWritesUnderSessionFolder() throws {
        let j = journal()
        let relative = try j.backUp(Data("old cover".utf8), relativePath: "Music/A/cover.jpg", sessionID: session)
        XCTAssertEqual(relative, "backups/\(session.uuidString)/Music/A/cover.jpg")
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(relative)), Data("old cover".utf8))

        // A second backup of the same file in one session keeps both.
        let second = try j.backUp(Data("newer".utf8), relativePath: "Music/A/cover.jpg", sessionID: session)
        XCTAssertNotEqual(second, relative)
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(relative)), Data("old cover".utf8))

        let source = j.folder.appendingPathComponent("device-file")
        try Data("from device".utf8).write(to: source)
        let copied = try j.backUp(fileAt: source, relativePath: "Notes/._a.txt", sessionID: session)
        XCTAssertEqual(copied, "backups/\(session.uuidString)/Notes/._a.txt")
        XCTAssertEqual(try Data(contentsOf: j.folder.appendingPathComponent(copied)), Data("from device".utf8))

        XCTAssertThrowsError(try j.backUp(Data(), relativePath: "../escape", sessionID: session))
    }

    func testReloadFromDiskSeesEarlierRecords() throws {
        let date = Date(timeIntervalSince1970: 1_794_435_900)
        try journal().append([DeviceFileRecord(relativePath: "Music/A/cover.jpg", kind: .created, role: "cover",
                                               size: 3, sha256: "abc", volumeUUID: "VOL", sessionID: session,
                                               date: date)])
        let reloaded = journal()
        let owned = try XCTUnwrap(reloaded.ownedRecord(forKey: "music/a/cover.jpg"))
        XCTAssertEqual(owned.date, date)
        XCTAssertEqual(owned.sessionID, session)
        XCTAssertEqual(owned.volumeUUID, "VOL")
        XCTAssertEqual(reloaded.records.count, 1)
    }

    func testTruncatedLastLineIsIgnoredAndOwnershipFailsSafe() throws {
        let j = journal()
        try j.append([record("Music/A/cover.jpg", .created)])
        try j.append([record("Music/B/cover.jpg", .created)])
        let url = j.folder.appendingPathComponent(DeviceWriteJournal.fileName)
        var bytes = try Data(contentsOf: url)
        let firstLineEnd = try XCTUnwrap(bytes.firstIndex(of: 0x0a))
        bytes = bytes.prefix(firstLineEnd + 1 + 40) // mid second line
        try bytes.write(to: url)

        let reloaded = journal()
        XCTAssertNotNil(reloaded.ownedRecord(forKey: "music/a/cover.jpg"))
        XCTAssertNil(reloaded.ownedRecord(forKey: "music/b/cover.jpg"))

        try reloaded.append([record("Music/C/cover.jpg", .created)])
        let third = journal()
        XCTAssertNotNil(third.ownedRecord(forKey: "music/a/cover.jpg"))
        XCTAssertNil(third.ownedRecord(forKey: "music/b/cover.jpg"))
        XCTAssertNotNil(third.ownedRecord(forKey: "music/c/cover.jpg"))
    }

    func testBlankLinesAreTolerated() throws {
        let j = journal()
        try j.append([record("Music/A/cover.jpg", .created)])
        let url = j.folder.appendingPathComponent(DeviceWriteJournal.fileName)
        let bytes = Data("\n\n".utf8) + (try Data(contentsOf: url)) + Data("\n   \n".utf8)
        try bytes.write(to: url)
        XCTAssertNotNil(journal().ownedRecord(forKey: "music/a/cover.jpg"))
    }

    func testMissingJournalMeansNothingOwned() {
        let j = journal()
        XCTAssertNil(j.ownedRecord(forKey: "music/a/cover.jpg"))
        XCTAssertEqual(j.records, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path)) // loading creates nothing
    }
}
