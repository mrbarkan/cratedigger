import SwiftUI
import PDFKit
import AppKit
import CrateDiggerCore
import ImageIO

// MARK: - Booklet Item Types
public enum BookletItem: Equatable, Sendable {
    case cover(Int)            // Single page centered (Front Cover)
    case back(Int)             // Single page centered (Back Cover)
    case wideSpread(Int)       // Wide pre-joined page spanning full width
    case dualPage(Int, Int?)   // Side-by-side single pages (left, optional right)
}

public enum PageSide: String, Equatable, Sendable {
    case left
    case right
}

// MARK: - Fullscreen Transparent Borderless Window
public final class BorderlessBookletWindow: NSWindow {
    init(contentView: AnyView) {
        let screenRect = NSScreen.main?.frame ?? .zero

        super.init(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false // Fix window closing crash
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating // Float above CrateDigger window
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: screenRect.size)
        hostingView.autoresizingMask = [.width, .height]

        self.contentView = hostingView
    }

    public override var canBecomeKey: Bool {
        return true
    }
}

// MARK: - Window Manager Singleton
public final class BookletWindowManager: NSObject, @unchecked Sendable {
    public static let shared = BookletWindowManager()
    private var activeWindow: BorderlessBookletWindow? = nil

    @MainActor
    public func showBooklet(_ booklet: AlbumBooklet, albumTitle: String, artistName: String, theme: CarbonTheme) {
        activeWindow?.close()

        let bookletView = AlbumBookletView(
            booklet: booklet,
            albumTitle: albumTitle,
            artistName: artistName,
            onClose: { [weak self] in
                self?.closeActiveWindow()
            }
        )
        .environment(\.carbon, theme)

        let window = BorderlessBookletWindow(contentView: AnyView(bookletView))
        window.makeKeyAndOrderFront(nil)
        self.activeWindow = window
    }

    @MainActor
    public func closeActiveWindow() {
        activeWindow?.close()
        activeWindow = nil
    }
}

// MARK: - Booklet View Model
@MainActor
final class BookletViewModel: ObservableObject {
    let booklet: AlbumBooklet

    @Published var pageCount: Int = 0
    @Published var currentSpreadIndex: Int = 0
    @Published var isDualPage: Bool = true
    @Published var renderedPages: [Int: NSImage] = [:]
    @Published var loadingPages: Set<Int> = []
    @Published var items: [BookletItem] = []
    @Published var isAnalyzing: Bool = true

    private var pdfDocument: PDFDocument? = nil
    private var imageURLs: [URL] = []
    private var pageAspectRatios: [CGFloat] = []

    init(booklet: AlbumBooklet) {
        self.booklet = booklet
        loadBooklet()
    }

    private func loadBooklet() {
        switch booklet.source {
        case .pdf(let url):
            if let doc = PDFDocument(url: url) {
                self.pdfDocument = doc
                let count = doc.pageCount
                self.pageCount = count

                var ratios: [CGFloat] = []
                for idx in 0..<count {
                    if let page = doc.page(at: idx) {
                        let bounds = page.bounds(for: .mediaBox)
                        ratios.append(bounds.height > 0 ? (bounds.width / bounds.height) : 1.0)
                    } else {
                        ratios.append(1.0)
                    }
                }
                self.pageAspectRatios = ratios
                self.items = buildBookletItems()
                self.isAnalyzing = false
            } else {
                self.isAnalyzing = false
            }
        case .images(let urls):
            // Exclude CD/disc labels entirely from page lists
            let filteredUrls = urls.filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let isDisc = name.contains("cd") || name.contains("disc") || name.contains("disk") || name.contains("vinyl") || name.contains("media") || name.contains("label") || name.contains("dvd")
                return !isDisc
            }
            let finalUrls = filteredUrls.isEmpty ? urls : filteredUrls
            self.imageURLs = finalUrls
            self.pageCount = finalUrls.count

            Task {
                let ratios = await computeImageAspectRatios(urls: finalUrls)
                await MainActor.run {
                    self.pageAspectRatios = ratios
                    self.items = self.buildBookletItems()
                    self.isAnalyzing = false
                }
            }
        }
    }

    private func computeImageAspectRatios(urls: [URL]) async -> [CGFloat] {
        var ratios: [CGFloat] = []
        for url in urls {
            if let size = imageSize(at: url) {
                ratios.append(size.height > 0 ? (size.width / size.height) : 1.0)
            } else {
                ratios.append(1.0)
            }
        }
        return ratios
    }

    private func imageSize(at url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions) as? [CFString: Any] else { return nil }
        guard let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    private func buildBookletItems() -> [BookletItem] {
        guard pageCount > 0 else { return [] }
        var result: [BookletItem] = []

        // Front Cover (Page 0)
        result.append(.cover(0))

        if pageCount == 1 {
            return result
        }

        var i = 1
        let limit = pageCount - 1 // Last page is Back Cover

        while i < limit {
            let aspect = pageAspectRatios[i]

            if aspect > 1.3 {
                // Pre-joined wide landscape spread
                result.append(.wideSpread(i))
                i += 1
            } else {
                // Single portrait page
                if i + 1 < limit {
                    let nextAspect = pageAspectRatios[i + 1]
                    if nextAspect <= 1.3 {
                        result.append(.dualPage(i, i + 1))
                        i += 2
                    } else {
                        // Next page is wide, show this page on its own
                        result.append(.dualPage(i, nil))
                        i += 1
                    }
                } else {
                    // Only one page left before Back Cover
                    result.append(.dualPage(i, nil))
                    i += 1
                }
            }
        }

        // Back Cover (Last Page)
        result.append(.back(pageCount - 1))

        return result
    }

    var isLastPage: Bool {
        if isDualPage {
            return currentSpreadIndex >= items.count - 1
        } else {
            return currentSpreadIndex >= pageCount - 1
        }
    }

    var isFirstPage: Bool {
        return currentSpreadIndex == 0
    }

    func nextPage() {
        if isDualPage {
            if currentSpreadIndex < items.count - 1 {
                currentSpreadIndex += 1
            }
        } else {
            if currentSpreadIndex < pageCount - 1 {
                currentSpreadIndex += 1
            }
        }
    }

    func prevPage() {
        if currentSpreadIndex > 0 {
            currentSpreadIndex -= 1
        }
    }

    func toggleLayoutMode() {
        if isDualPage {
            guard currentSpreadIndex < items.count else { return }
            let item = items[currentSpreadIndex]
            let targetPage: Int
            switch item {
            case .cover(let idx), .back(let idx), .wideSpread(let idx):
                targetPage = idx
            case .dualPage(let l, _):
                targetPage = l
            }
            isDualPage = false
            currentSpreadIndex = targetPage
        } else {
            let targetPage = currentSpreadIndex
            isDualPage = true
            if let index = items.firstIndex(where: { item in
                switch item {
                case .cover(let idx) where idx == targetPage: return true
                case .back(let idx) where idx == targetPage: return true
                case .wideSpread(let idx) where idx == targetPage: return true
                case .dualPage(let l, let r) where l == targetPage || r == targetPage: return true
                default: return false
                }
            }) {
                currentSpreadIndex = index
            } else {
                currentSpreadIndex = 0
            }
        }
    }

    func image(for index: Int) -> NSImage? {
        if let cached = renderedPages[index] {
            return cached
        }
        loadPage(index)
        return nil
    }

    private func loadPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        guard !loadingPages.contains(index) else { return }

        loadingPages.insert(index)

        if let pdfDoc = pdfDocument {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            Task.detached(priority: .userInitiated) {
                guard let page = pdfDoc.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)

                let maxDim: CGFloat = 1600.0 // Higher res for fullscreen
                let aspect = bounds.height > 0 ? (bounds.width / bounds.height) : 1.0
                let size: CGSize
                if aspect > 1 {
                    size = CGSize(width: maxDim * scale, height: (maxDim / aspect) * scale)
                } else {
                    size = CGSize(width: (maxDim * aspect) * scale, height: maxDim * scale)
                }

                let image = NSImage(size: size)
                image.lockFocus()
                if let context = NSGraphicsContext.current?.cgContext {
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
                    page.draw(with: .mediaBox, to: context)
                }
                image.unlockFocus()

                await MainActor.run {
                    self.renderedPages[index] = image
                    self.loadingPages.remove(index)
                }
            }
        } else {
            let url = imageURLs[index]
            Task.detached(priority: .userInitiated) {
                if let image = NSImage(contentsOf: url) {
                    await MainActor.run {
                        self.renderedPages[index] = image
                        self.loadingPages.remove(index)
                    }
                }
            }
        }
    }
}

// MARK: - Album Booklet View
struct AlbumBookletView: View {
    @Environment(\.carbon) private var theme
    @StateObject private var viewModel: BookletViewModel
    let albumTitle: String
    let artistName: String
    let onClose: () -> Void

    @State private var eventMonitor: Any? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var dragPosition: CGSize = .zero

    init(booklet: AlbumBooklet, albumTitle: String, artistName: String, onClose: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: BookletViewModel(booklet: booklet))
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            // Fullscreen Transparent Backdrop (Click outside the booklet to close)
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            if viewModel.isAnalyzing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("ANALYZING BOOKLET...")
                        .font(CarbonFont.mono(9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Booklet content centered and padded
                ZStack {
                    if viewModel.isDualPage {
                        dualPageSpread
                    } else {
                        singlePageView
                    }

                    // Left & Right Click zones overlayed on the booklet for page changing
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.prevPage()
                                }
                                .frame(width: geo.size.width * 0.35) // Left 35% turns back

                            Spacer()

                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.nextPage()
                                }
                                .frame(width: geo.size.width * 0.35) // Right 35% turns forward
                        }
                    }
                }
                .frame(maxWidth: 1200, maxHeight: 800) // Beautiful large centered booklet size
                .padding(60)
                .offset(x: dragPosition.width + dragOffset.width, y: dragPosition.height + dragOffset.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            dragPosition.width += value.translation.width
                            dragPosition.height += value.translation.height
                            dragOffset = .zero
                        }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - Dual Page Spread
    private var dualPageSpread: some View {
        Group {
            if viewModel.items.count > viewModel.currentSpreadIndex {
                let item = viewModel.items[viewModel.currentSpreadIndex]

                switch item {
                case .cover(let idx):
                    // Front Cover (Centered single page)
                    BookletPageView(image: viewModel.image(for: idx))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 6)
                        .frame(maxWidth: 580, maxHeight: 580)
                        .id("cover-\(idx)")

                case .back(let idx):
                    // Back Cover (Centered single page)
                    BookletPageView(image: viewModel.image(for: idx))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 6)
                        .frame(maxWidth: 580, maxHeight: 580)
                        .id("back-\(idx)")

                case .wideSpread(let idx):
                    // Wide pre-joined landscape spread. Raw view without crease gradients.
                    BookletPageView(image: viewModel.image(for: idx))
                        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 8)
                        .frame(maxWidth: 1100, maxHeight: 600)
                        .id("wide-\(idx)")

                case .dualPage(let leftIdx, let rightIdx):
                    // Open Single Pages side-by-side
                    HStack(spacing: 0) {
                        BookletPageView(image: viewModel.image(for: leftIdx))

                        if let rightIdx = rightIdx {
                            // Divider line where pages meet
                            Rectangle()
                                .fill(Color.black.opacity(0.12))
                                .frame(width: 1)
                                .zIndex(5)

                            BookletPageView(image: viewModel.image(for: rightIdx))
                        } else {
                            Color.clear
                                .aspectRatio(1.0, contentMode: .fit)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 8)
                    .frame(maxWidth: 1100, maxHeight: 600)
                    .id("spread-\(leftIdx)")
                }
            } else {
                Text("No pages available.")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Single Page View
    private var singlePageView: some View {
        Group {
            if viewModel.pageCount > 0 {
                BookletPageView(image: viewModel.image(for: viewModel.currentSpreadIndex))
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 6)
                    .frame(maxWidth: 580, maxHeight: 580)
                    .id("single-\(viewModel.currentSpreadIndex)")
            } else {
                Text("No pages available.")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Keyboard Monitoring
    private func setupKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 124 { // Right arrow
                viewModel.nextPage()
                return nil
            } else if event.keyCode == 123 { // Left arrow
                viewModel.prevPage()
                return nil
            } else if event.keyCode == 53 { // Esc
                onClose()
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Booklet Page View Component
struct BookletPageView: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Color.white

            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .aspectRatio(contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 1)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}
