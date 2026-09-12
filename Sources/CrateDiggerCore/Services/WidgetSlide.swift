import AppKit
import CryptoKit
import ImageIO
import PDFKit

/// One picture the Now Playing widget can show, and how the app makes it.
///
/// The widget is sandboxed away from the library, so the app renders each
/// picture to a small JPEG in the shared container and names it in the feed.
public enum WidgetSlide: Hashable, Sendable {
    /// A cover from the artwork store.
    case artwork(hash: String)
    /// A scanned booklet page.
    case image(URL)
    /// A page of a PDF booklet, zero-based.
    case pdfPage(URL, index: Int)

    /// Booklet pages in a slideshow, after the cover. A 40-page booklet would
    /// otherwise take 40 minutes to come round and fill the container.
    public static let maxBookletPages = 12

    /// The picture's file name in the container. A cover is named by its hash,
    /// a page by its path, so the same picture is only ever rendered once.
    public var fileName: String {
        switch self {
        case .artwork(let hash): return "art-\(hash).jpg"
        case .image(let url): return "page-\(Self.digest(url.path)).jpg"
        case .pdfPage(let url, let index): return "page-\(Self.digest(url.path))-\(index).jpg"
        }
    }

    /// The playing album's slideshow: its cover, then up to `maxBookletPages`
    /// booklet pages. A scanned booklet's first image is its front cover (see
    /// `AlbumBooklet.sortAndCategorizeBookletImages`), so it is skipped when
    /// the album already has artwork rather than shown twice. A PDF cannot be
    /// read that way, so all of its pages count.
    public static func albumSlides(coverHash: String?, booklet: AlbumBooklet?, pdfPageCount: (URL) -> Int) -> [WidgetSlide] {
        var slides: [WidgetSlide] = coverHash.map { [.artwork(hash: $0)] } ?? []
        switch booklet?.source {
        case .images(let urls)?:
            let pages = coverHash == nil ? urls : Array(urls.dropFirst())
            slides += pages.prefix(maxBookletPages).map { .image($0) }
        case .pdf(let url)?:
            slides += (0..<min(pdfPageCount(url), maxBookletPages)).map { .pdfPage(url, index: $0) }
        case nil:
            break
        }
        return slides
    }

    public static func pdfPageCount(_ url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// A JPEG of the picture no larger than `maxPixel` on its long side, or nil
    /// when it cannot be read. Safe off the main thread.
    public func renderJPEG(maxPixel: Int, artworkData: (String) -> Data?) -> Data? {
        let cgImage: CGImage?
        switch self {
        case .artwork(let hash):
            cgImage = artworkData(hash).flatMap {
                Self.thumbnail(of: CGImageSourceCreateWithData($0 as CFData, nil), maxPixel: maxPixel)
            }
        case .image(let url):
            cgImage = Self.thumbnail(of: CGImageSourceCreateWithURL(url as CFURL, nil), maxPixel: maxPixel)
        case .pdfPage(let url, let index):
            // ponytail: opens the PDF once per page; fine for 12 pages, hand the
            // renderer one PDFDocument if large booklets turn out slow.
            cgImage = Self.render(page: PDFDocument(url: url)?.page(at: index), maxPixel: maxPixel)
        }
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func thumbnail(of source: CGImageSource?, maxPixel: Int) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func render(page: PDFPage?, maxPixel: Int) -> CGImage? {
        guard let page else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = CGFloat(maxPixel) / max(bounds.width, bounds.height, 1)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
