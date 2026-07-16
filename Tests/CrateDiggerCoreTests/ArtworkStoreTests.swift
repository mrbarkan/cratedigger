import AppKit
import XCTest
@testable import CrateDiggerCore

final class ArtworkStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A JPEG of the requested size — stands in for a real cover.
    private func imageData(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
    }

    func testPutThenGetRoundTrips() {
        let store = ArtworkStore(directory: directory)
        // Not a decodable image: stored verbatim (the conservative fallback).
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        store.put(bytes, for: "abc123")
        XCTAssertTrue(store.contains("abc123"))
        XCTAssertEqual(store.data(for: "abc123"), bytes)
    }

    func testPutStoresThumbnailNotFullResolution() throws {
        let store = ArtworkStore(directory: directory)
        let full = try imageData(width: 1500, height: 1500)
        store.put(full, for: "cover")

        let stored = try XCTUnwrap(store.data(for: "cover"))
        XCTAssertLessThan(stored.count, full.count, "the store must not keep full-resolution bytes")
        let rep = try XCTUnwrap(NSImage(data: stored)?.representations.first)
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), ArtworkThumbnail.maxPixel)
    }

    func testMissingHashReturnsNil() {
        let store = ArtworkStore(directory: directory)
        XCTAssertFalse(store.contains("nope"))
        XCTAssertNil(store.data(for: "nope"))
    }

    func testWriteOnceDoesNotOverwriteExistingBlob() {
        let store = ArtworkStore(directory: directory)
        store.put(Data([1, 2, 3]), for: "h")
        store.put(Data([9, 9, 9]), for: "h")   // a hash addresses fixed bytes; never rewritten
        XCTAssertEqual(store.data(for: "h"), Data([1, 2, 3]))
    }

    func testEmptyDataIsIgnored() {
        let store = ArtworkStore(directory: directory)
        store.put(Data(), for: "empty")
        XCTAssertFalse(store.contains("empty"))
        XCTAssertNil(store.data(for: "empty"))
    }

    func testSurvivesAcrossStoreInstances() {
        ArtworkStore(directory: directory).put(Data([7, 7]), for: "persisted")
        // A fresh instance on the same directory (i.e. a relaunch) still resolves it.
        XCTAssertEqual(ArtworkStore(directory: directory).data(for: "persisted"), Data([7, 7]))
    }

    func testClearDropsEveryThumbnail() {
        let store = ArtworkStore(directory: directory)
        store.put(Data([1, 2, 3]), for: "a")
        store.put(Data([4, 5, 6]), for: "b")

        store.clear()

        XCTAssertFalse(store.contains("a"))
        XCTAssertFalse(store.contains("b"))
        // The directory is usable again straight away, not left missing.
        store.put(Data([7, 8, 9]), for: "c")
        XCTAssertTrue(store.contains("c"))
    }
}

final class ArtworkStoreMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var thumbnails: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        legacy = root.appendingPathComponent("Artwork")
        thumbnails = root.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeLegacyBlob(_ data: Data, hash: String) throws {
        try data.write(to: legacy.appendingPathComponent(hash))
    }

    private func imageData(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width / 3, height: height / 3).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
    }

    func testMigrationShrinksBlobsAndDeletesLegacyDirectory() throws {
        let full = try imageData(width: 1600, height: 1600)
        try writeLegacyBlob(full, hash: "cover-hash")

        let store = ArtworkStore(directory: thumbnails)
        let reclaimed = store.migrateLegacyFullResolutionStore(at: legacy)

        XCTAssertEqual(reclaimed, full.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy store must be deleted")
        // The cover still resolves offline — just far smaller.
        let migrated = try XCTUnwrap(store.data(for: "cover-hash"))
        XCTAssertLessThan(migrated.count, full.count)
    }

    func testMigrationSkipsUnreadableBlobsAndKeepsGoing() throws {
        try writeLegacyBlob(try imageData(width: 900, height: 900), hash: "good")
        // A directory where a blob should be: unreadable as Data, must not abort.
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("broken"),
            withIntermediateDirectories: true
        )

        let store = ArtworkStore(directory: thumbnails)
        store.migrateLegacyFullResolutionStore(at: legacy)

        XCTAssertNotNil(store.data(for: "good"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMigrationIsANoOpWithoutLegacyDirectory() throws {
        try FileManager.default.removeItem(at: legacy)
        let store = ArtworkStore(directory: thumbnails)
        XCTAssertEqual(store.migrateLegacyFullResolutionStore(at: legacy), 0)
    }
}

final class ArtworkAssetCodableTests: XCTestCase {
    func testEncodeOmitsBytesButKeepsMetadata() throws {
        let asset = ArtworkAsset(
            source: .embedded,
            hash: "hash-1",
            dimensions: ArtworkDimensions(width: 600, height: 600),
            data: Data([0x01, 0x02, 0x03, 0x04])
        )
        let json = try JSONEncoder().encode(asset)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("\"data\""), "encoded artwork must not carry image bytes")

        let decoded = try JSONDecoder().decode(ArtworkAsset.self, from: json)
        XCTAssertEqual(decoded.hash, "hash-1")
        XCTAssertEqual(decoded.source, .embedded)
        XCTAssertEqual(decoded.dimensions, ArtworkDimensions(width: 600, height: 600))
        XCTAssertTrue(decoded.data.isEmpty, "round-tripped bytes live in the store, not the JSON")
    }

    func testDecodesLegacyEmbeddedBytesForMigration() throws {
        // An older `.cdlib` embedded the bytes inline; the decoder must still read
        // them so a migration can move them into the ArtworkStore.
        let legacyBytes = Data([0xAA, 0xBB, 0xCC])
        let legacy = """
        {
            "source": "embedded",
            "hash": "legacy-hash",
            "dimensions": { "width": 300, "height": 300 },
            "data": "\(legacyBytes.base64EncodedString())"
        }
        """
        let decoded = try JSONDecoder().decode(ArtworkAsset.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.data, legacyBytes)
        XCTAssertEqual(decoded.hash, "legacy-hash")
    }
}
