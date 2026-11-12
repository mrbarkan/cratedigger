import XCTest
@testable import CrateDiggerCore

/// The words around a cleanup: the question before it, the answer after
/// it, and the hint that there is something to clean.
final class DeviceCleanupSummaryTests: XCTestCase {
    private func plan(candidates: Int, leftAlone: [String: Int] = [:]) -> AppleDoubleSweepPlan {
        AppleDoubleSweepPlan(candidates: (0..<candidates).map { "Music/A/._\($0).m4a" }, leftAlone: leftAlone,
                             sizeHistogram: [4096: candidates])
    }

    func testConfirmationWithCountAndLeftAlone() {
        let text = DeviceCleanupSummary.confirmation(
            plan(candidates: 1_731, leftAlone: ["not media": 10, "too large": 2]), deviceName: "IPOD")
        XCTAssertEqual(text.title, "Remove Mac files from IPOD?")
        XCTAssertTrue(text.message.contains("1,731 Mac metadata files found."), text.message)
        XCTAssertTrue(text.message.contains("They are not music. A copy is kept on this Mac."), text.message)
        XCTAssertTrue(text.message.contains("12 other files are left alone."), text.message)
    }

    func testConfirmationSingular() {
        let text = DeviceCleanupSummary.confirmation(plan(candidates: 1), deviceName: "IPOD")
        XCTAssertTrue(text.message.hasPrefix("1 Mac metadata file found. It is not music."), text.message)
        XCTAssertFalse(text.message.contains("left alone"), text.message)
        let one = DeviceCleanupSummary.confirmation(plan(candidates: 2, leftAlone: ["not media": 1]), deviceName: "IPOD")
        XCTAssertTrue(one.message.contains("1 other file is left alone."), one.message)
    }

    func testResultWithRefusals() {
        XCTAssertEqual(DeviceCleanupSummary.result(removed: 1_729, refused: 2, leftAlone: [:]),
                       "Removed 1,729 Mac metadata files. 2 could not be verified and were left.")
        XCTAssertEqual(DeviceCleanupSummary.result(removed: 1, refused: 1, leftAlone: ["not media": 3]),
                       "Removed 1 Mac metadata file. 1 could not be verified and was left. 3 other files are left alone.")
        XCTAssertEqual(DeviceCleanupSummary.result(removed: 4, refused: 0, leftAlone: [:]),
                       "Removed 4 Mac metadata files.")
    }

    func testMountHintNilAtZero() {
        XCTAssertNil(DeviceCleanupSummary.mountHint(count: 0))
        XCTAssertEqual(DeviceCleanupSummary.mountHint(count: 1_731), "PodBox is reading 1,731 Mac files as music.")
        XCTAssertEqual(DeviceCleanupSummary.mountHint(count: 1), "PodBox is reading 1 Mac file as music.")
    }

    func testNoEmDashAnywhere() {
        var texts: [String] = []
        for count in [0, 1, 2, 1_731] {
            let confirm = DeviceCleanupSummary.confirmation(plan(candidates: count, leftAlone: ["not media": count]),
                                                             deviceName: "IPOD")
            texts += [confirm.title, confirm.message,
                      DeviceCleanupSummary.result(removed: count, refused: count, leftAlone: ["x": count]),
                      DeviceCleanupSummary.mountHint(count: count) ?? "",
                      DeviceCleanupSummary.nothingFound]
        }
        for text in texts { XCTAssertFalse(text.contains("\u{2014}"), text) }
    }

    // MARK: - Finishing a session

    func testFinishSweepsOnlyTheFoldersWrittenAndSaysWhatToDo() throws {
        let iPod = try FakeIPod()
        let written = try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                                        tracks: ["01 - Zebra.m4a"], cover: false, appleDoubleTwins: true)
        let other = try iPod.addAlbum(category: "Classics", artist: "Low", folder: "1994 I Could Live in Hope",
                                      tracks: ["01 - Words.m4a"], cover: false, appleDoubleTwins: true)
        let before = try iPod.manifest()
        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceSessionFinish-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let journal = DeviceWriteJournal(profileID: UUID(), directory: journalDir)
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: "V",
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          volumeUUID: { _ in "V" }, freeSpace: { _ in 1 << 40 },
                                          rootMustBeMountPoint: false)
        let firmware = DeviceFirmwareProbe.probe(volumeRoot: iPod.root)

        let result = DeviceSessionFinish.finish(
            written: [written.appendingPathComponent("01 - Zebra.m4a")], deleted: [], changes: .audio,
            firmware: firmware, sweeps: true, volumeRoot: iPod.root,
            sweeper: AppleDoubleSweeper(fileSystemType: { _ in "msdos" }), executor: executor)

        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.changes, [.audio, .cleanup])
        XCTAssertEqual(result.lines.first, "Removed 1 Mac metadata file.")
        XCTAssertEqual(Array(result.lines.dropFirst()), PodBoxNextSteps.after([.audio, .cleanup], firmware: firmware))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.appendingPathComponent("._01 - Zebra.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("._01 - Words.m4a").path),
                      "a folder the session did not touch is left as it is")
        XCTAssertEqual(journal.records.filter { $0.kind == .deleted }.compactMap(\.backupFile).count, 1,
                       "the removed twin is kept on the Mac")
        iPod.assertPlayerStateUntouched(since: before)
    }

    func testFinishWithoutSweepOnlyGivesNextSteps() throws {
        let iPod = try FakeIPod()
        let written = try iPod.addAlbum(category: nil, artist: "A", folder: "B", tracks: ["01.m4a"], cover: false,
                                        appleDoubleTwins: true)
        let journal = DeviceWriteJournal(profileID: UUID(), directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceSessionFinish-\(UUID().uuidString)", isDirectory: true))
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: "V",
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          volumeUUID: { _ in "V" }, rootMustBeMountPoint: false)

        let result = DeviceSessionFinish.finish(
            written: [written.appendingPathComponent("01.m4a")], deleted: [], changes: [.audio, .covers],
            firmware: nil, sweeps: false, volumeRoot: iPod.root, executor: executor)

        XCTAssertEqual(result.lines, ["Eject the device before unplugging."])
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.appendingPathComponent("._01.m4a").path))
    }

    func testFinishWithNothingWrittenSaysNothing() throws {
        let iPod = try FakeIPod()
        let journal = DeviceWriteJournal(profileID: UUID(), directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceSessionFinish-\(UUID().uuidString)", isDirectory: true))
        let executor = DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: "V",
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          volumeUUID: { _ in "V" }, rootMustBeMountPoint: false)
        let result = DeviceSessionFinish.finish(written: [], deleted: [], changes: [], firmware: nil, sweeps: true,
                                                volumeRoot: iPod.root, executor: executor)
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(journal.records, [])
    }

    func testOutcomeChanges() {
        var outcome = DeviceTransferExecutor.Outcome()
        XCTAssertEqual(outcome.changes(coversWritten: 0), [])
        XCTAssertEqual(outcome.changes(coversWritten: 2), [.covers])
        outcome.deleted = [URL(fileURLWithPath: "/V/Music/a.mp3")]
        XCTAssertEqual(outcome.changes(coversWritten: 0), [.audio])
        XCTAssertEqual(DeviceCleanupSummary.nothingFoundDetail(deviceName: "IPOD", leftAlone: ["not media": 2]),
                       "Nothing on IPOD needs removing. 2 other files are left alone.")
    }

    func testAutomaticCleanupIsOffUntilTurnedOn() throws {
        var preferences = PodBoxPreferences()
        XCTAssertFalse(preferences.appleDoubleCleanup)
        let old = try JSONDecoder().decode(PodBoxPreferences.self, from: Data(#"{"sweepsAppleDouble":true}"#.utf8))
        XCTAssertFalse(old.appleDoubleCleanup, "a profile saved before the switch reads it as off")
        XCTAssertFalse(DeviceSessionFinish.sweepsAfterTransfer(capabilities: .appleDoubleSweep, preferences: preferences))
        preferences.appleDoubleCleanup = true
        XCTAssertTrue(DeviceSessionFinish.sweepsAfterTransfer(capabilities: .appleDoubleSweep, preferences: preferences))
        XCTAssertFalse(DeviceSessionFinish.sweepsAfterTransfer(capabilities: [], preferences: preferences),
                       "never on a volume that is not FAT or exFAT")
        let round = try JSONDecoder().decode(PodBoxPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(round.appleDoubleCleanup)
    }
}

