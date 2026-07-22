#if canImport(XCTest)
import AppKit
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ArtworkHydrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func asset(hash: String, data: Data) -> ArtworkAsset {
        ArtworkAsset(
            source: .embedded,
            hash: hash,
            dimensions: ArtworkDimensions(width: 10, height: 10),
            data: data
        )
    }

    private func imageData(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
    }

    /// A track file URL inside `directory` — the file itself need not exist
    /// unless the test is exercising folder-cover resolution.
    private func trackURL(_ name: String = "01 Track.flac") -> URL {
        directory.appendingPathComponent(name)
    }

    func testHydratedRefillsEmptyDataFromCacheByHash() async {
        // Mirrors the .cdlib round-trip: the asset keeps its hash but loses its
        // bytes; hydration must find them again by hash.
        let service = ArtworkService()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        service.ingest(asset(hash: "cover-hash", data: bytes))

        let stripped = asset(hash: "cover-hash", data: Data())
        let hydrated = await service.hydrated(stripped, trackURL: trackURL())
        XCTAssertEqual(hydrated.data, bytes)
    }

    func testHydratedLeavesPresentDataUntouched() async {
        let service = ArtworkService()
        let present = asset(hash: "h", data: Data([1, 2, 3]))
        let hydrated = await service.hydrated(present, trackURL: trackURL())
        XCTAssertEqual(hydrated.data, Data([1, 2, 3]))
    }

    func testHydratedReturnsEmptyWhenNothingResolves() async {
        let service = ArtworkService()
        let unknown = asset(hash: "not-cached", data: Data())
        let hydrated = await service.hydrated(unknown, trackURL: trackURL())
        XCTAssertTrue(hydrated.data.isEmpty)
    }

    /// The whole point of the 1.1.0 cache change: the disk store holds
    /// thumbnails, so hydration must go back to the SOURCE for full-resolution
    /// bytes rather than handing a 512px thumbnail to the re-embedder.
    func testHydratedReadsFullResolutionFromSourceNotTheThumbnailStore() async throws {
        let store = ArtworkStore(directory: directory.appendingPathComponent("Thumbnails"))
        let service = ArtworkService(store: store)

        let full = try imageData(width: 1400, height: 1400)
        let hash = "folder-cover"
        // The album folder carries the canonical cover…
        try full.write(to: directory.appendingPathComponent("cover.jpg"))
        // …while the disk cache only ever saw a thumbnail of it.
        store.put(full, for: hash)
        let cachedThumbnail = try XCTUnwrap(store.data(for: hash))
        XCTAssertLessThan(cachedThumbnail.count, full.count, "precondition: the store holds a thumbnail")

        let stripped = ArtworkAsset(
            source: .folderImage,
            hash: hash,
            dimensions: ArtworkDimensions(width: 1400, height: 1400),
            data: Data()
        )
        let hydrated = await service.hydrated(stripped, trackURL: trackURL())

        XCTAssertEqual(hydrated.data, full, "hydration must return the source bytes, not the cached thumbnail")
        // Full resolution, i.e. well past what the thumbnail cache would hold.
        // (Compared against the source's own pixel width rather than a literal:
        // NSImage renders at the display's backing scale, so a "1400pt" canvas
        // is 2800px on a Retina Mac.)
        let hydratedRep = try XCTUnwrap(NSImage(data: hydrated.data)?.representations.first)
        let sourceRep = try XCTUnwrap(NSImage(data: full)?.representations.first)
        XCTAssertEqual(hydratedRep.pixelsWide, sourceRep.pixelsWide)
        XCTAssertGreaterThan(hydratedRep.pixelsWide, ArtworkThumbnail.maxPixel)
    }
}
#endif
