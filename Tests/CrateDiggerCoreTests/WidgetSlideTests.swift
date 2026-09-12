#if canImport(XCTest)
import AppKit
import XCTest
@testable import CrateDiggerCore

final class WidgetSlideTests: XCTestCase {

    private let pdf = URL(fileURLWithPath: "/m/Album/booklet.pdf")

    private func scans(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/m/Album/scans/\($0).jpg") }
    }

    private func slides(cover: String?, _ source: AlbumBookletSource?, pdfPages: Int = 0) -> [WidgetSlide] {
        WidgetSlide.albumSlides(coverHash: cover, booklet: source.map(AlbumBooklet.init(source:)),
                                pdfPageCount: { _ in pdfPages })
    }

    // MARK: Names

    func testACoverIsNamedByItsHash() {
        XCTAssertEqual(WidgetSlide.artwork(hash: "abc").fileName, "art-abc.jpg")
    }

    func testEveryBookletPageHasItsOwnStableName() {
        let pages: [WidgetSlide] = [.image(scans(2)[0]), .image(scans(2)[1]), .pdfPage(pdf, index: 0), .pdfPage(pdf, index: 1)]
        XCTAssertEqual(Set(pages.map(\.fileName)).count, 4)
        XCTAssertEqual(WidgetSlide.pdfPage(pdf, index: 1).fileName, WidgetSlide.pdfPage(pdf, index: 1).fileName)
    }

    // MARK: The album's slideshow

    func testTheCoverLeadsAndTheScannedFrontIsNotRepeated() {
        XCTAssertEqual(slides(cover: "abc", .images(scans(3))),
                       [.artwork(hash: "abc"), .image(scans(3)[1]), .image(scans(3)[2])])
    }

    func testWithoutArtworkTheScannedFrontLeads() {
        XCTAssertEqual(slides(cover: nil, .images(scans(2))), [.image(scans(2)[0]), .image(scans(2)[1])])
    }

    func testEveryPDFPageCountsAfterTheCover() {
        XCTAssertEqual(slides(cover: "abc", .pdf(pdf), pdfPages: 2),
                       [.artwork(hash: "abc"), .pdfPage(pdf, index: 0), .pdfPage(pdf, index: 1)])
    }

    func testBookletPagesAreCapped() {
        XCTAssertEqual(slides(cover: "abc", .images(scans(40))).count, 1 + WidgetSlide.maxBookletPages)
        let pdfSlides = slides(cover: "abc", .pdf(pdf), pdfPages: 40)
        XCTAssertEqual(pdfSlides.count, 1 + WidgetSlide.maxBookletPages)
        XCTAssertEqual(pdfSlides.last, .pdfPage(pdf, index: WidgetSlide.maxBookletPages - 1))
    }

    func testNoBookletIsJustTheCover() {
        XCTAssertEqual(slides(cover: "abc", nil), [.artwork(hash: "abc")])
        XCTAssertEqual(slides(cover: nil, nil), [])
    }

    // MARK: Rendering

    func testAScanIsRenderedDownToSize() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSlideTests-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let jpeg = try XCTUnwrap(WidgetSlide.image(url).renderJPEG(maxPixel: 300, artworkData: { _ in nil }))
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(rendered.pixelsWide, 300)
        XCTAssertEqual(rendered.pixelsHigh, 150)
    }

    func testMissingArtworkRendersNothing() {
        XCTAssertNil(WidgetSlide.artwork(hash: "abc").renderJPEG(maxPixel: 300, artworkData: { _ in nil }))
        XCTAssertNil(WidgetSlide.image(URL(fileURLWithPath: "/nonexistent.jpg")).renderJPEG(maxPixel: 300, artworkData: { _ in nil }))
    }

    // MARK: Captions

    func testARecordIsCreditedToItsSmallestCrate() {
        let crates: [(name: String, paths: Set<String>)] = [
            ("Personal Crate", ["/a", "/b", "/c"]),
            ("Jazz", ["/a", "/b"]),
            ("Vinyls", ["/a"])
        ]
        XCTAssertEqual(WidgetCaption.crate(containing: "/a", in: crates), "Vinyls")
        XCTAssertEqual(WidgetCaption.crate(containing: "/b", in: crates), "Jazz")
        XCTAssertEqual(WidgetCaption.crate(containing: "/c", in: crates), "Personal Crate")
        XCTAssertNil(WidgetCaption.crate(containing: "/d", in: crates))
    }

    func testATieGoesToTheCrateListedFirst() {
        let crates: [(name: String, paths: Set<String>)] = [("Rock", ["/a"]), ("Heavy", ["/a"])]
        XCTAssertEqual(WidgetCaption.crate(containing: "/a", in: crates), "Rock")
    }
}
#endif
