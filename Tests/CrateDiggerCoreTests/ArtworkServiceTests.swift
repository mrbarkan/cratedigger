#if canImport(XCTest)
import AppKit
import XCTest
@testable import CrateDiggerCore

final class ArtworkServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateDiggerArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFolderArtworkFallbackResolvesCoverJPG() async throws {
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

    func testGenerateThumbnailAfterResolve() async throws {
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

    private func makeImageData(size: NSSize, fileType: NSBitmapImageRep.FileType) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.72, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 12
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: size.width, y: size.height))
        path.stroke()

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: fileType, properties: [.compressionFactor: 0.9])
        else {
            throw NSError(domain: "ArtworkServiceTests", code: 1)
        }

        return data
    }
}
#endif
