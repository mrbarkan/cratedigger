import AppKit
import XCTest
@testable import CrateDiggerCore

final class ArtworkThumbnailTests: XCTestCase {
    /// A solid-colour JPEG of the requested size — stands in for a real cover.
    private func imageData(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // A second colour so the encoder can't collapse it to a trivial image.
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
    }

    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let image = try XCTUnwrap(NSImage(data: data))
        let rep = try XCTUnwrap(image.representations.first)
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func testDownscalesLargeCoverWithinMaxPixel() throws {
        let full = try imageData(width: 1400, height: 1400)
        let thumb = try XCTUnwrap(ArtworkThumbnail.encode(full))

        let size = try pixelSize(of: thumb)
        XCTAssertLessThanOrEqual(max(size.width, size.height), ArtworkThumbnail.maxPixel)
        XCTAssertLessThan(thumb.count, full.count, "a downscaled thumbnail must be smaller than the original")
    }

    func testPreservesAspectRatio() throws {
        let full = try imageData(width: 1200, height: 600)
        let thumb = try XCTUnwrap(ArtworkThumbnail.encode(full))

        let size = try pixelSize(of: thumb)
        XCTAssertEqual(size.width, ArtworkThumbnail.maxPixel)
        XCTAssertLessThanOrEqual(abs(size.height - ArtworkThumbnail.maxPixel / 2), 1, "aspect ratio drifted")
    }

    func testAlreadySmallImageIsNotGrown() throws {
        // Re-encoding a tiny image can produce MORE bytes than the original;
        // the encoder keeps whichever is smaller.
        let small = try imageData(width: 64, height: 64)
        let thumb = try XCTUnwrap(ArtworkThumbnail.encode(small))
        XCTAssertLessThanOrEqual(thumb.count, small.count)
    }

    func testUndecodableDataReturnsNil() {
        XCTAssertNil(ArtworkThumbnail.encode(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }
}
