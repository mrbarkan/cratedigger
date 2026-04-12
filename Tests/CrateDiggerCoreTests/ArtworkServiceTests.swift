#if canImport(XCTest)
import AppKit
import XCTest
@testable import CrateDiggerCore

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
}
#endif
