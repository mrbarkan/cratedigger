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

    func testPutThenGetRoundTrips() {
        let store = ArtworkStore(directory: directory)
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        store.put(bytes, for: "abc123")
        XCTAssertTrue(store.contains("abc123"))
        XCTAssertEqual(store.data(for: "abc123"), bytes)
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
