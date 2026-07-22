#if canImport(XCTest)
import AppKit
import XCTest
@testable import CrateDiggerCore

/// Counts `fileExists(atPath:)` probes so tests can assert the per-folder
/// artwork memo skips disk entirely on a second track in the same folder.
private final class FileExistsCountingFileManager: FileManager {
    private let lock = NSLock()
    private var count = 0

    var fileExistsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        return super.fileExists(atPath: path)
    }
}

final class ArtworkServiceTests: XCTestCase {
    func testFolderArtworkFallbackResolvesCoverJPG() async throws {
        try await withTemporaryDirectory(prefix: "CrateDiggerArtworkTests") { temporaryDirectory in
            let trackURL = temporaryDirectory.appendingPathComponent("track.mp3")
            FileManager.default.createFile(atPath: trackURL.path, contents: Data("test".utf8))

            let coverURL = temporaryDirectory.appendingPathComponent("cover.jpg")
            let coverData = try makeImageData(size: NSSize(width: 512, height: 512), fileType: .jpeg)
            try coverData.write(to: coverURL, options: .atomic)

            let service = ArtworkService()
            let artwork = await service.resolveArtwork(trackURL: trackURL)

            XCTAssertNotNil(artwork)
            XCTAssertEqual(artwork?.source, .folderImage)
            XCTAssertGreaterThan(artwork?.dimensions.width ?? 0, 0)
            XCTAssertGreaterThan(artwork?.dimensions.height ?? 0, 0)
            XCTAssertFalse(artwork?.hash.isEmpty ?? true)
        }
    }

    func testGenerateThumbnailAfterResolve() async throws {
        try await withTemporaryDirectory(prefix: "CrateDiggerArtworkTests") { temporaryDirectory in
            let trackURL = temporaryDirectory.appendingPathComponent("track.flac")
            FileManager.default.createFile(atPath: trackURL.path, contents: Data("test".utf8))

            let coverURL = temporaryDirectory.appendingPathComponent("AlbumArtLarge.png")
            let coverData = try makeImageData(size: NSSize(width: 1200, height: 800), fileType: .png)
            try coverData.write(to: coverURL, options: .atomic)

            let service = ArtworkService()
            let artwork = await service.resolveArtwork(trackURL: trackURL)
            XCTAssertNotNil(artwork)

            let thumbnail = service.generateThumbnail(artworkHash: artwork!.hash, size: CGSize(width: 48, height: 48))
            XCTAssertNotNil(thumbnail)
            XCTAssertEqual(Int(thumbnail?.size.width ?? 0), 48)
            XCTAssertEqual(Int(thumbnail?.size.height ?? 0), 48)
        }
    }

    func testPrepareCompatibleArtworkForLegacyIPod() throws {
        let pngData = try makeImageData(size: NSSize(width: 2200, height: 2200), fileType: .png)

        let asset = ArtworkAsset(
            source: .embedded,
            hash: "original",
            dimensions: ArtworkDimensions(width: 2200, height: 2200),
            data: pngData
        )

        let service = ArtworkService()
        let compatible = try service.prepareCompatibleArtwork(asset: asset, profile: .ipodLegacySafe)

        XCTAssertLessThanOrEqual(compatible.dimensions.width, 600)
        XCTAssertLessThanOrEqual(compatible.dimensions.height, 600)
        XCTAssertLessThanOrEqual(compatible.data.count, 300_000)
        XCTAssertEqual(compatible.data.prefix(2), Data([0xFF, 0xD8]))
    }

    func testFolderArtworkIsMemoizedPerFolder() async throws {
        try await withTemporaryDirectory(prefix: "CrateDiggerArtworkTests") { temporaryDirectory in
            let coverData = try makeImageData(size: NSSize(width: 400, height: 400), fileType: .jpeg)
            try coverData.write(to: temporaryDirectory.appendingPathComponent("cover.jpg"), options: .atomic)

            let firstTrackURL = temporaryDirectory.appendingPathComponent("track1.mp3")
            let secondTrackURL = temporaryDirectory.appendingPathComponent("track2.mp3")
            FileManager.default.createFile(atPath: firstTrackURL.path, contents: Data("one".utf8))
            FileManager.default.createFile(atPath: secondTrackURL.path, contents: Data("two".utf8))

            let spy = FileExistsCountingFileManager()
            let service = ArtworkService(fileManager: spy)

            let first = await service.resolveArtwork(trackURL: firstTrackURL)
            let probesAfterFirst = spy.fileExistsCallCount
            XCTAssertNotNil(first)
            XCTAssertEqual(first?.source, .folderImage)
            XCTAssertGreaterThan(probesAfterFirst, 0)

            // Second track in the same folder: same asset, zero new disk probes.
            let second = await service.resolveArtwork(trackURL: secondTrackURL)
            XCTAssertEqual(second?.hash, first?.hash)
            XCTAssertEqual(second?.data, first?.data)
            XCTAssertEqual(spy.fileExistsCallCount, probesAfterFirst)

            // Clearing the memo makes the next lookup re-probe the disk.
            service.clearFolderArtworkMemo()
            let third = await service.resolveArtwork(trackURL: firstTrackURL)
            XCTAssertEqual(third?.hash, first?.hash)
            XCTAssertGreaterThan(spy.fileExistsCallCount, probesAfterFirst)
        }
    }

    func testPrepareCompatibleArtworkRepeatedCallsAreByteIdentical() throws {
        let pngData = try makeImageData(size: NSSize(width: 2200, height: 2200), fileType: .png)
        let asset = ArtworkAsset(
            source: .embedded,
            hash: "repeat-source",
            dimensions: ArtworkDimensions(width: 2200, height: 2200),
            data: pngData
        )

        let service = ArtworkService()
        let first = try service.prepareCompatibleArtwork(asset: asset, profile: .ipodLegacySafe)
        let second = try service.prepareCompatibleArtwork(asset: asset, profile: .ipodLegacySafe)

        XCTAssertEqual(second.data, first.data)
        XCTAssertEqual(second.hash, first.hash)
        XCTAssertEqual(second.dimensions, first.dimensions)

        // A different (profile, maxDimension) key must not collide in the memo.
        let smaller = try service.prepareCompatibleArtwork(asset: asset, profile: .generic, maxDimension: 300)
        XCTAssertLessThanOrEqual(smaller.dimensions.width, 300)
        let smallerAgain = try service.prepareCompatibleArtwork(asset: asset, profile: .generic, maxDimension: 300)
        XCTAssertEqual(smallerAgain.data, smaller.data)
    }

    func testPrepareCompatibleArtworkNoopForGenericProfile() throws {
        let jpegData = try makeImageData(size: NSSize(width: 300, height: 300), fileType: .jpeg)

        let asset = ArtworkAsset(
            source: .embedded,
            hash: "unchanged",
            dimensions: ArtworkDimensions(width: 300, height: 300),
            data: jpegData
        )

        let service = ArtworkService()
        let same = try service.prepareCompatibleArtwork(asset: asset, profile: .generic)

        XCTAssertEqual(same.hash, asset.hash)
        XCTAssertEqual(same.data, asset.data)
    }

    func testRemoveCachedDropsTheStoredThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ArtworkStore(directory: directory)
        let service = ArtworkService(store: store)
        store.put(Data("stored-bytes".utf8), for: "cafebabe")
        XCTAssertTrue(store.contains("cafebabe"))

        service.removeCached(hash: "cafebabe")

        XCTAssertFalse(store.contains("cafebabe"))
    }
}
#endif
