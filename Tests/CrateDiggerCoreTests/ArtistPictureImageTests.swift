import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CrateDiggerCore

final class ArtistPictureImageTests: XCTestCase {
    // MARK: - Inputs drawn here

    private struct Pixel: Equatable { let r, g, b: UInt8 }

    /// An sRGB image of `width` × `height`, filled by `fill` (x, y) -> RGBA.
    private func image(_ width: Int, _ height: Int, alpha: Bool = false,
                       fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = fill(x, y)
                let i = (y * width + x) * 4
                // Premultiplied, as the context expects.
                bytes[i] = UInt8(Int(r) * Int(a) / 255)
                bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
                bytes[i + 2] = UInt8(Int(b) * Int(a) / 255)
                bytes[i + 3] = a
            }
        }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: info)!
        return context.makeImage()!
    }

    private func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        image(width, height) { _, _ in (r, g, b, 255) }
    }

    private func encode(_ images: [CGImage], as type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func jpeg(_ image: CGImage) -> Data { encode([image], as: .jpeg) }

    /// Seeded noise, so the test is the same every run.
    private func noise(_ width: Int, _ height: Int) -> CGImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        return image(width, height) { _, _ in (next(), next(), next(), 255) }
    }

    // MARK: - Reading the output

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4 // the context's rows run top down in memory
        return Pixel(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
    }

    /// The JPEG markers from SOI up to and including SOS (the header), in order.
    private func headerMarkers(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return [] }
        var markers: [UInt8] = [0xD8]
        var i = 2
        while i + 3 < bytes.count {
            guard bytes[i] == 0xFF else { return markers + [0x00] } // corrupt: make the test fail
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }
            markers.append(marker)
            if marker == 0xDA { break }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 2 + length
        }
        return markers
    }

    private func close(_ a: UInt8, _ b: UInt8, within tolerance: Int = 12) -> Bool { abs(Int(a) - Int(b)) <= tolerance }

    // MARK: - Tests

    func testSquareSourceGives400SquareJPEG() throws {
        let output = try XCTUnwrap(ArtistPictureImage.prepare(jpeg(solid(800, 800, 200, 40, 40))))
        let image = try decoded(output)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 400)
        XCTAssertEqual(Array(output.prefix(2)), [0xFF, 0xD8])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(image.colorSpace?.model, .rgb)
        XCTAssertEqual(ArtistPictureImage.edge, 400)
        XCTAssertEqual(ArtistPictureImage.minimumSource, 300)
        XCTAssertEqual(ArtistPictureImage.maximumBytes, 100 * 1024)
        XCTAssertEqual(ArtistPictureImage.maximumSourcePixels, 12_000)
    }

    func testOutputIsBaselineNotProgressive() throws {
        // Even a progressive source comes out baseline.
        let progressive = encode([noise(600, 600)], as: .jpeg, properties: [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ])
        XCTAssertTrue(headerMarkers(progressive).contains(0xC2), "the input really is progressive")
        let output = try XCTUnwrap(ArtistPictureImage.prepare(progressive))
        let markers = headerMarkers(output)
        XCTAssertEqual(markers.last, 0xDA, "the header parses up to the scan")
        XCTAssertTrue(markers.contains(0xC0), "baseline SOF0")
        XCTAssertFalse(markers.contains(0xC2), "no progressive SOF2")
    }

    func testOutputHasNoEXIF() throws {
        let tagged = encode([solid(600, 600, 10, 120, 200)], as: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "someone"],
        ])
        XCTAssertTrue(headerMarkers(tagged).contains(0xE1), "the input carries EXIF")
        let output = try XCTUnwrap(ArtistPictureImage.prepare(tagged))
        XCTAssertFalse(headerMarkers(output).contains(0xE1), "no APP1 (EXIF or XMP) segment")
        XCTAssertNil(output.range(of: Data("secret".utf8)))
        XCTAssertNil(output.range(of: Data("someone".utf8)))
    }

    func testOutputAtMost100KB() throws {
        let source = encode([noise(1200, 1200)], as: .png)
        XCTAssertGreaterThan(source.count, 1_000_000)
        let output = try XCTUnwrap(ArtistPictureImage.prepare(source))
        XCTAssertLessThanOrEqual(output.count, 100 * 1024)
        XCTAssertEqual(try decoded(output).width, 400)
    }

    func testPortraitCropIsBiasedToTheTopThird() {
        XCTAssertEqual(ArtistPictureImage.cropRect(for: CGSize(width: 600, height: 900)),
                       CGRect(x: 0, y: 100, width: 600, height: 600))
        // Drawn: a red band in the top third of a portrait survives the crop.
        let portrait = image(600, 900) { _, y in y < 100 ? (0, 0, 255, 255) : (y < 400 ? (255, 0, 0, 255) : (0, 255, 0, 255)) }
        let output = try? decoded(XCTUnwrap(ArtistPictureImage.prepare(jpeg(portrait))))
        if let output {
            let top = pixel(output, x: 200, y: 20)
            XCTAssertTrue(close(top.r, 255) && close(top.g, 0) && close(top.b, 0), "\(top)")
        } else {
            XCTFail("no output")
        }
    }

    func testLandscapeCropIsCentred() {
        XCTAssertEqual(ArtistPictureImage.cropRect(for: CGSize(width: 900, height: 600)),
                       CGRect(x: 150, y: 0, width: 600, height: 600))
        XCTAssertEqual(ArtistPictureImage.cropRect(for: CGSize(width: 500, height: 500)),
                       CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    func testTooSmallIsNil() {
        XCTAssertNil(ArtistPictureImage.prepare(jpeg(solid(299, 400, 1, 2, 3))))
        XCTAssertNotNil(ArtistPictureImage.prepare(jpeg(solid(300, 400, 1, 2, 3))))
    }

    func testBannerIsNil() {
        XCTAssertNil(ArtistPictureImage.prepare(jpeg(solid(1500, 500, 1, 2, 3))))
        XCTAssertNil(ArtistPictureImage.prepare(jpeg(solid(400, 1000, 1, 2, 3))), "too tall as well")
        XCTAssertNotNil(ArtistPictureImage.prepare(jpeg(solid(1000, 500, 1, 2, 3))), "2:1 exactly is fine")
    }

    func testGiantIsNilWithoutDecoding() {
        let small = jpeg(solid(400, 400, 1, 2, 3))
        XCTAssertNotNil(ArtistPictureImage.prepare(small, reportedSize: CGSize(width: 400, height: 400)))
        XCTAssertNil(ArtistPictureImage.prepare(small, reportedSize: CGSize(width: 20_000, height: 15_000)))
        XCTAssertNil(ArtistPictureImage.prepare(small, reportedSize: CGSize(width: 12_001, height: 12_000)))
    }

    func testHugeAreaOrHugeFileIsNilWithoutDecoding() {
        let small = jpeg(solid(400, 400, 1, 2, 3))
        XCTAssertNil(ArtistPictureImage.prepare(small, reportedSize: CGSize(width: 8_000, height: 7_000)),
                     "56 megapixels, each side within 12,000")
        XCTAssertNotNil(ArtistPictureImage.prepare(small, reportedSize: CGSize(width: 7_000, height: 7_000)))
        XCTAssertNotNil(ArtistPictureImage.prepare(small + Data(count: 1_000)), "bytes after the end marker are fine")
        XCTAssertNil(ArtistPictureImage.prepare(small + Data(count: ArtistPictureImage.maximumSourceBytes)))
    }

    func testFormatsThatCannotBeCheckedAreRefused() throws {
        let tiff = encode([solid(500, 500, 9, 9, 9)], as: .tiff)
        XCTAssertNil(ArtistPictureImage.prepare(tiff))
        let gif = encode([solid(500, 500, 9, 9, 9)], as: .gif)
        XCTAssertNotNil(ArtistPictureImage.prepare(gif))
        XCTAssertNil(ArtistPictureImage.prepare(gif.dropLast()), "no trailer")
        XCTAssertNil(ArtistPictureImage.prepare(gif.prefix(gif.count * 2 / 3)))
    }

    func testAlphaPNGGetsWhiteBackground() throws {
        let clear = image(500, 500, alpha: true) { x, _ in x < 250 ? (0, 0, 0, 0) : (0, 0, 255, 255) }
        let output = try decoded(XCTUnwrap(ArtistPictureImage.prepare(encode([clear], as: .png))))
        XCTAssertEqual(output.alphaInfo == .none || output.alphaInfo == .noneSkipLast || output.alphaInfo == .noneSkipFirst,
                       true, "no alpha in a JPEG")
        let left = pixel(output, x: 50, y: 200)
        XCTAssertTrue(close(left.r, 255) && close(left.g, 255) && close(left.b, 255), "white, not black: \(left)")
        let right = pixel(output, x: 350, y: 200)
        XCTAssertTrue(close(right.b, 255) && close(right.r, 0), "\(right)")
    }

    func testCMYKJPEGBecomesSRGB() throws {
        let cmyk = CGContext(data: nil, width: 500, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        cmyk.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [0, 1, 1, 0, 1])!)
        cmyk.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        let input = jpeg(cmyk.makeImage()!)
        let inputImage = try decoded(input)
        XCTAssertEqual(inputImage.colorSpace?.model, .cmyk, "the input really is CMYK")

        let output = try decoded(XCTUnwrap(ArtistPictureImage.prepare(input)))
        XCTAssertEqual(output.colorSpace?.model, .rgb)
        let centre = pixel(output, x: 200, y: 200)
        XCTAssertGreaterThan(Int(centre.r), 150, "red stays red: \(centre)")
        XCTAssertLessThan(Int(centre.g), 100, "\(centre)")
    }

    func testAnimatedGIFUsesFirstFrame() throws {
        let gif = encode([solid(400, 400, 255, 0, 0), solid(400, 400, 0, 0, 255)], as: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let output = try decoded(XCTUnwrap(ArtistPictureImage.prepare(gif)))
        let centre = pixel(output, x: 200, y: 200)
        XCTAssertTrue(close(centre.r, 255, within: 30) && close(centre.b, 0, within: 30), "first frame (red): \(centre)")
    }

    func testZeroBytesAndTruncatedAreNil() {
        XCTAssertNil(ArtistPictureImage.prepare(Data()))
        XCTAssertNil(ArtistPictureImage.prepare(Data("not an image at all".utf8)))
        let whole = jpeg(noise(600, 600))
        XCTAssertNotNil(ArtistPictureImage.prepare(whole))
        XCTAssertNil(ArtistPictureImage.prepare(whole.prefix(whole.count / 2)))
        XCTAssertNil(ArtistPictureImage.prepare(whole.prefix(200)), "a header and nothing else")
        XCTAssertNil(ArtistPictureImage.prepare(whole.dropLast(2)), "everything but the end marker")
        let png = encode([noise(500, 500)], as: .png)
        XCTAssertNotNil(ArtistPictureImage.prepare(png))
        XCTAssertNil(ArtistPictureImage.prepare(png.prefix(png.count / 2)))
        let progressive = encode([noise(600, 600)], as: .jpeg, properties: [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ])
        XCTAssertNotNil(ArtistPictureImage.prepare(progressive), "several scans still reach the end")
        XCTAssertNil(ArtistPictureImage.prepare(progressive.prefix(progressive.count * 2 / 3)))
    }

    func testSameInputGivesSameBytes() {
        let input = jpeg(noise(700, 500))
        let first = ArtistPictureImage.prepare(input)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, ArtistPictureImage.prepare(input))
    }
}
