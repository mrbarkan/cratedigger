#if canImport(XCTest)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CrateDiggerApp

/// The artist photo viewer keeps nothing larger than it can show: about
/// twice the screen's pixels, never an original upscaled.
final class ArtistPhotoDecodeTests: XCTestCase {
    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testALargePhotoIsDecodedToTheCap() throws {
        let image = try XCTUnwrap(ArtistPhotoDecode.image(jpeg(4_000, 3_000), maxPixel: 1_000))
        XCTAssertEqual(ArtworkGeometry.pixelSize(of: image), CGSize(width: 1_000, height: 750))
    }

    func testASmallPhotoIsNeverUpscaled() throws {
        let image = try XCTUnwrap(ArtistPhotoDecode.image(jpeg(600, 400), maxPixel: 5_000))
        XCTAssertEqual(ArtworkGeometry.pixelSize(of: image), CGSize(width: 600, height: 400))
    }

    func testNothingReadableIsNil() {
        XCTAssertNil(ArtistPhotoDecode.image(nil, maxPixel: 1_000))
        XCTAssertNil(ArtistPhotoDecode.image(Data("not a picture".utf8), maxPixel: 1_000))
    }

    func testTheCapIsTwiceTheScreensLongSideInPixels() {
        XCTAssertEqual(ArtistPhotoDecode.side(for: nil), 1_920 * 2 * 2)
    }
}
#endif
