import CryptoKit
import XCTest
@testable import CrateDiggerCore

final class ArtistPictureStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPictureStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var indexDirectory: URL { folder.appendingPathComponent("Index", isDirectory: true) }
    private var imageDirectory: URL { folder.appendingPathComponent("ArtistImages", isDirectory: true) }

    private func makeStore() throws -> ArtistPictureStore {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        return ArtistPictureStore(indexDirectory: indexDirectory, imageDirectory: imageDirectory)
    }

    private func record(_ name: String, _ outcome: ArtistPictureRecord.Outcome = .found,
                        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> ArtistPictureRecord {
        ArtistPictureRecord(foldedKey: PodBoxArtName.folded(name), displayName: name, outcome: outcome,
                            source: .deezer, sourceID: "42", checkedAt: checkedAt)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testSetThenRecordByAnySpelling() throws {
        let store = try makeStore()
        try store.set(record("The Beatles"), prepared: nil)
        XCTAssertEqual(store.record(forName: "Beatles, The")?.displayName, "The Beatles")
        XCTAssertEqual(store.record(forName: "beatles")?.foldedKey, "beatles")
        XCTAssertNil(store.record(forName: "The Rolling Stones"))
        XCTAssertNil(store.record(forName: "!!!"), "a name with no key has no record")

        // A second spelling replaces the first: one record per key.
        try store.set(record("Beatles", .rejected), prepared: nil)
        XCTAssertEqual(store.allRecords().count, 1)
        XCTAssertEqual(store.record(forName: "The Beatles")?.outcome, .rejected)
    }

    func testPreparedBytesRoundTrip() throws {
        let store = try makeStore()
        let bytes = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        try store.set(record("Björk"), prepared: bytes)
        let stored = try XCTUnwrap(store.record(forName: "Bjork"))
        XCTAssertEqual(stored.preparedHash, sha256(bytes))
        XCTAssertEqual(store.preparedData(for: stored), bytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: imageDirectory.appendingPathComponent(sha256(bytes) + ".jpg").path))
    }

    func testMissingImageFileGivesNilData() throws {
        let store = try makeStore()
        let bytes = Data([1, 2, 3])
        try store.set(record("Air"), prepared: bytes)
        let stored = try XCTUnwrap(store.record(forName: "Air"))
        try FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(sha256(bytes) + ".jpg"))
        XCTAssertNil(store.preparedData(for: stored))

        var noHash = stored
        noHash.preparedHash = nil
        XCTAssertNil(store.preparedData(for: noHash))
        noHash.preparedHash = "../../etc/passwd"
        XCTAssertNil(store.preparedData(for: noHash), "only a hex hash names a file")
    }

    func testSaveAndReload() throws {
        let store = try makeStore()
        let bytes = Data([9, 8, 7])
        var picked = record("AC/DC")
        picked.pickedByUser = true
        picked.source = .userFile
        try store.set(picked, prepared: bytes)
        try store.set(record("Sigur Rós", .notFound), prepared: nil)
        try store.save()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: indexDirectory.appendingPathComponent("library.cdartists").path))
        let reloaded = ArtistPictureStore(indexDirectory: indexDirectory, imageDirectory: imageDirectory)
        XCTAssertEqual(reloaded.allRecords(), store.allRecords())
        XCTAssertEqual(reloaded.allRecords().map(\.foldedKey), ["acdc", "sigurros"])
        let acdc = try XCTUnwrap(reloaded.record(forName: "ACDC"))
        XCTAssertTrue(acdc.pickedByUser)
        XCTAssertEqual(reloaded.preparedData(for: acdc), bytes)
        XCTAssertEqual(ArtistPictureStore.fileName, "library.cdartists")
    }

    func testUnreadableFileIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let file = indexDirectory.appendingPathComponent(ArtistPictureStore.fileName)
        try Data("not json".utf8).write(to: file)
        let store = ArtistPictureStore(indexDirectory: indexDirectory, imageDirectory: imageDirectory)
        try store.set(record("Air"), prepared: nil)
        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
    }

    func testAnyOtherReadErrorBlocksSaving() throws {
        // A folder where the file should be: not "missing", so not "empty".
        let file = indexDirectory.appendingPathComponent(ArtistPictureStore.fileName, isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = ArtistPictureStore(indexDirectory: indexDirectory, imageDirectory: imageDirectory)
        try store.set(record("Air"), prepared: nil)
        XCTAssertThrowsError(try store.save()) { error in
            XCTAssertEqual(error as? ArtistPictureStoreError, .unreadableStore(path: file.path))
        }
    }

    func testOneRecordForBothOrdersOfACommaName() throws {
        let store = try makeStore()
        try store.set(record("Herbert, Frank"), prepared: nil)
        XCTAssertEqual(store.record(forName: "Frank Herbert")?.displayName, "Herbert, Frank")
        try store.set(record("Frank Herbert", .rejected), prepared: nil)
        XCTAssertEqual(store.allRecords().map(\.displayName), ["Frank Herbert"])
        XCTAssertEqual(store.record(forName: "Herbert, Frank")?.outcome, .rejected)
        try store.save()
        let reloaded = ArtistPictureStore(indexDirectory: indexDirectory, imageDirectory: imageDirectory)
        XCTAssertEqual(reloaded.record(forName: "Herbert, Frank")?.displayName, "Frank Herbert")
    }

    func testSetWorksOutOrChecksTheFoldedKey() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.set(record("!!!"), prepared: nil)) { error in
            XCTAssertEqual(error as? ArtistPictureStoreError, .invalidRecord(name: "!!!"))
        }
        var wrong = record("Air")
        wrong.foldedKey = "beck"
        XCTAssertThrowsError(try store.set(wrong, prepared: nil))
        var blank = record("The Beatles")
        blank.foldedKey = ""
        try store.set(blank, prepared: nil)
        XCTAssertEqual(store.allRecords().map(\.foldedKey), ["beatles"])
    }

    func testNotFoundIsStaleAfterThirtyDays() {
        let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let notFound = record("Air", .notFound, checkedAt: checked)
        let day: TimeInterval = 86_400
        XCTAssertFalse(notFound.isStale(now: checked.addingTimeInterval(29 * day)))
        XCTAssertFalse(notFound.isStale(now: checked.addingTimeInterval(30 * day)))
        XCTAssertTrue(notFound.isStale(now: checked.addingTimeInterval(30 * day + 1)))
        XCTAssertFalse(record("Air", .found, checkedAt: checked).isStale(now: checked.addingTimeInterval(400 * day)))
        XCTAssertFalse(record("Air", .uncertain, checkedAt: checked).isStale(now: checked.addingTimeInterval(400 * day)))
    }

    func testRejectedIsNeverStale() {
        let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertFalse(record("Air", .rejected, checkedAt: checked).isStale(now: checked.addingTimeInterval(3_650 * 86_400)))
    }

    func testIndexFilesIncludeCdartists() {
        XCTAssertTrue(LibraryIndexFiles.extensions.contains("cdartists"))
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/library.cdartists")))
    }
}
