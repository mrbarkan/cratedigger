import AppKit
import CrateDiggerCore
import SwiftUI

/// A small, movable, resizable panel that keeps album art on screen while the
/// user keeps working in the main window. Non-activating so clicking or dragging
/// it never steals key focus (Edit Tags etc. stay usable), floating so it stays
/// on top, titled so macOS gives free edge-resize handles. Its own ✕ pill closes
/// it, so the native window buttons are hidden.
public final class FloatingArtworkPanel: NSPanel {
    init(content: AnyView, near reference: NSWindow?) {
        let size = NSSize(width: 340, height: 400)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true          // drag the art to move the panel
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Chromeless: the art floats with a transparent surround, rendering exactly
        // like the full-screen viewer (just without the dimmed backdrop). Edge-resize
        // still works because the window stays titled+resizable.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        minSize = NSSize(width: 220, height: 260)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        // Tuck into the top-right of the app window, else center on screen.
        if let ref = reference {
            let rf = ref.frame
            setFrameTopLeftPoint(NSPoint(x: rf.maxX - size.width - 24, y: rf.maxY - 24))
        } else {
            center()
        }
    }

    public override var canBecomeKey: Bool { true }
}

/// Presents the album artwork navigator two ways: full-screen over the app (the
/// same window class the booklet viewer uses, so it sits above CrateDigger without
/// disturbing the current source or selection), or — via the FLOAT button — popped
/// out into a small `FloatingArtworkPanel` that stays open while you keep using the
/// app. PDF booklets still open the richer `AlbumBookletView` (see the `showArtwork`
/// wiring in `MainShell`); everything else — cover, booklet scans, inlay, disc,
/// back, and the composited "tray" page — flows through this navigator.
@MainActor
enum ArtworkViewerPresenter {
    private static var window: BorderlessBookletWindow?
    private static var panel: FloatingArtworkPanel?

    /// Full-screen presentation. `index` restores the page the user was on when
    /// docking back from the floating panel.
    static func show(album: Album, theme: CarbonTheme, model: LibraryViewModel, index: Int = 0) {
        closeAll()
        let pages = buildPages(album)
        let view = AlbumArtworkNavigator(
            album: album,
            pages: pages,
            startIndex: index,
            floating: false,
            onClose: { close() },
            onFloat: { idx in float(album: album, theme: theme, model: model, index: idx) }
        )
        .environmentObject(model)
        .environment(\.carbon, theme)
        let w = BorderlessBookletWindow(contentView: AnyView(view))
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Floating-panel presentation. Opens at `index` and can expand back to
    /// full-screen at whatever page it's showing.
    static func float(album: Album, theme: CarbonTheme, model: LibraryViewModel, index: Int) {
        let reference = NSApp.mainWindow
        closeAll()
        let pages = buildPages(album)
        let view = AlbumArtworkNavigator(
            album: album,
            pages: pages,
            startIndex: index,
            floating: true,
            onClose: { closeFloating() },
            onExpand: { idx in show(album: album, theme: theme, model: model, index: idx) }
        )
        .environmentObject(model)
        .environment(\.carbon, theme)
        let p = FloatingArtworkPanel(content: AnyView(view), near: reference)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    static func close() { closeAll() }

    static func closeFloating() {
        panel?.close()
        panel = nil
    }

    private static func closeAll() {
        window?.close(); window = nil
        panel?.close(); panel = nil
    }

    private static func buildPages(_ album: Album) -> [ArtworkPage] {
        let albumFolder = album.tracks.first?.track.fileURL.deletingLastPathComponent()
        var pages = albumFolder.map { AlbumArtCatalog.pages(in: $0) } ?? []
        // Always guarantee a Cover page: when no cover file is on disk, a synthetic
        // one renders the album's embedded/resolved artwork via AlbumPoster.
        if !pages.contains(where: { $0.kind == .cover }) {
            pages.insert(ArtworkPage(kind: .cover, label: "Cover", imageURL: nil), at: 0)
        }
        return pages
    }
}

/// How the current image is scaled in the viewport.
private enum ArtZoom: Equatable {
    case fit               // aspect-fit the viewport (default)
    case scale(CGFloat)    // multiple of the image's native pixel size (points)

    var label: String {
        switch self {
        case .fit: return "FIT"
        case .scale(let s): return "\(Int((s * 100).rounded()))%"
        }
    }
}

/// The album artwork navigator: pages through every piece of art an album has —
/// cover, booklet scans, inlay, disc, back — as large as the screen allows, with
/// the controls parked in a reserved strip below so they never cover the art. The
/// disc + inlay "tray" page composites the disc onto the tray card. Zoom (50 % /
/// 100 % / Fit / 1:1 with drag-to-pan) and a Focus toggle (darken the backdrop)
/// live in the control bar. Left/right arrows page; Esc closes.
struct AlbumArtworkNavigator: View {
    @Environment(\.carbon) private var theme
    let album: Album
    let pages: [ArtworkPage]
    /// Full-screen overlay when false; small always-on-top panel when true.
    let floating: Bool
    let onClose: () -> Void
    /// Full-screen only: pop out into the floating panel at the current page.
    var onFloat: ((Int) -> Void)? = nil
    /// Floating only: dock back to full-screen at the current page.
    var onExpand: ((Int) -> Void)? = nil

    @State private var index: Int
    @State private var images: [URL: NSImage] = [:]
    @State private var zoom: ArtZoom = .fit
    @State private var pan: CGSize = .zero
    @State private var dragPan: CGSize = .zero
    @State private var eventMonitor: Any?
    /// Pointer is over the floating panel — lights its frame.
    @State private var floatingHovering = false
    /// Focus mode darkens the backdrop so nothing behind competes with the art.
    @AppStorage("artworkFocusMode") private var focusMode = false

    init(album: Album, pages: [ArtworkPage], startIndex: Int = 0, floating: Bool = false,
         onClose: @escaping () -> Void, onFloat: ((Int) -> Void)? = nil, onExpand: ((Int) -> Void)? = nil) {
        self.album = album
        self.pages = pages
        self.floating = floating
        self.onClose = onClose
        self.onFloat = onFloat
        self.onExpand = onExpand
        _index = State(initialValue: max(0, min(startIndex, max(0, pages.count - 1))))
    }

    private var current: ArtworkPage? { pages.indices.contains(index) ? pages[index] : nil }

    var body: some View {
        Group {
            if floating { floatingBody } else { fullscreenBody }
        }
        // Arrow/Esc key capture only in full-screen — a floating panel must not
        // hijack the browser's arrow-key navigation while the user works.
        .onAppear { if !floating { installKeyMonitor() } }
        .onDisappear { removeKeyMonitor() }
        .task(id: index) { await loadCurrent() }
        .onChange(of: index) { _ in resetView() }
    }

    private var fullscreenBody: some View {
        ZStack {
            Color.black.opacity(focusMode ? 0.94 : 0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                artworkViewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.top, 32)

                controlCluster
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
    }

    private var floatingBody: some View {
        VStack(spacing: 0) {
            artworkViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 16)

            floatingControls
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // A fine frame around the floating panel: near-black at rest, lit cyan when
        // the pointer is over it, so it reads as a live, grabbable window.
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    floatingHovering ? theme.cyan : Color.black.opacity(0.6),
                    lineWidth: floatingHovering ? 1.5 : 1
                )
                .shadow(color: floatingHovering ? theme.cyan.opacity(0.6) : .clear, radius: 6)
                .padding(1)
                .animation(.easeInOut(duration: 0.18), value: floatingHovering)
        )
        .onHover { floatingHovering = $0 }
    }

    // MARK: - Artwork viewport (fills all remaining space)

    private var artworkViewport: some View {
        GeometryReader { geo in
            ZStack {
                // Full-screen: taps in the letterbox area around the art dismiss the
                // viewer. Floating: empty space is left free so the drag moves the panel.
                if !floating {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onClose() }
                }

                artworkContent(viewport: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func artworkContent(viewport: CGSize) -> some View {
        if let page = current {
            switch page.kind {
            case .tray:
                trayComposite(page, viewport: viewport)
                    .onTapGesture {}   // consume; don't dismiss on the art itself
            default:
                if page.imageURL == nil {
                    // Synthetic cover backed by the album's embedded/resolved art.
                    AlbumPoster(album: album)
                        .frame(width: min(viewport.width, viewport.height),
                               height: min(viewport.width, viewport.height))
                        .onTapGesture {}
                } else if let image = page.imageURL.flatMap({ images[$0] }) {
                    zoomableImage(image, viewport: viewport)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder
    private func zoomableImage(_ image: NSImage, viewport: CGSize) -> some View {
        switch zoom {
        case .fit:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
                .onTapGesture {}   // consume so a tap on the art doesn't dismiss

        case .scale(let scale):
            let native = pixelSize(of: image)
            let display = CGSize(width: native.width * scale, height: native.height * scale)
            Image(nsImage: image)
                .resizable()
                .frame(width: display.width, height: display.height)
                .offset(clampedPan(display: display, viewport: viewport))
                .gesture(panGesture(display: display, viewport: viewport))
        }
    }

    /// The "CD box" tray page: inlay/tray card behind, disc on top as a circle
    /// with a center hole, dropped in with a shadow like a seated disc.
    private func trayComposite(_ page: ArtworkPage, viewport: CGSize) -> some View {
        let inlayImage = page.imageURL.flatMap { images[$0] }
        // Size the disc to ≈ the inlay's displayed height, like a CD seated in its
        // tray card — not a fixed fraction of the whole viewport.
        let inlayHeight = fittedSize(of: inlayImage, in: viewport)?.height ?? min(viewport.width, viewport.height)
        let disc = inlayHeight
        return ZStack {
            if let inlay = inlayImage {
                Image(nsImage: inlay)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
            }

            if let discURL = page.overlayURL, let discImage = images[discURL] {
                Image(nsImage: discImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: disc, height: disc)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .overlay(
                        Circle()
                            .fill(Color.black.opacity(0.82))
                            .frame(width: disc * 0.14, height: disc * 0.14)
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control cluster (parked below the art, never overlapping it)

    private var controlCluster: some View {
        VStack(spacing: 8) {
            Text(album.title)
                .font(CarbonFont.sans(21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(caption)
                    .foregroundStyle(.white.opacity(0.7))
                if let role = current?.label {
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Text(role.uppercased()).foregroundStyle(theme.orange)
                }
            }
            .font(CarbonFont.mono(11, weight: .bold))
            .tracking(1.4)
            .lineLimit(1)

            HStack(spacing: 10) {
                pillButton(label: "BACK", icon: "chevron.left") { step(-1) }
                    .disabled(pages.count <= 1)

                pillButton(label: "CLOSE") { onClose() }

                pillButton(label: "FWD", icon: "chevron.right") { step(1) }
                    .disabled(pages.count <= 1)

                zoomMenu

                pillButton(label: "FOCUS", highlighted: focusMode) { focusMode.toggle() }

                pillButton(label: "FLOAT") { onFloat?(index) }
            }
            .padding(.top, 4)
        }
    }

    private var zoomMenu: some View {
        Menu {
            Button("Fit to Screen") { setZoom(.fit) }
            Button("50%") { setZoom(.scale(0.5)) }
            Button("100%") { setZoom(.scale(1.0)) }
            Button("1:1 (drag to pan)") { setZoom(.scale(1.0)) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold))
                Text(zoom.label).font(CarbonFont.mono(9.5, weight: .bold)).tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pillButton(label: String, icon: String? = nil, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon, icon == "chevron.left" { Image(systemName: icon) }
                Text(label).font(CarbonFont.mono(9.5, weight: .bold)).tracking(1.5)
                if let icon, icon == "chevron.right" { Image(systemName: icon) }
            }
            .foregroundStyle(highlighted ? theme.orange : .white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(highlighted ? 0.20 : 0.10)))
        }
        .buttonStyle(.carbonHover)
    }

    // MARK: - Floating panel controls (compact, pinned at the bottom)

    private var floatingControls: some View {
        VStack(spacing: 6) {
            if let role = current?.label {
                Text(role.uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.orange)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                iconPill("chevron.left") { step(-1) }.disabled(pages.count <= 1)
                zoomMenu
                iconPill("chevron.right") { step(1) }.disabled(pages.count <= 1)
                Spacer(minLength: 4)
                iconPill("arrow.up.left.and.arrow.down.right") { onExpand?(index) }   // dock back to full-screen
                iconPill("xmark") { onClose() }
            }
            .padding(.horizontal, 14)
        }
    }

    private func iconPill(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 28)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.carbonHover)
    }

    // MARK: - Behavior

    private var caption: String {
        var parts = [album.artistName.uppercased()]
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private func step(_ delta: Int) {
        guard !pages.isEmpty else { return }
        index = (index + delta + pages.count) % pages.count
    }

    private func setZoom(_ newZoom: ArtZoom) {
        zoom = newZoom
        pan = .zero
        dragPan = .zero
    }

    private func resetView() {
        pan = .zero
        dragPan = .zero
        zoom = .fit
    }

    private func panGesture(display: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { dragPan = $0.translation }
            .onEnded { value in
                pan = clampOffset(CGSize(width: pan.width + value.translation.width,
                                         height: pan.height + value.translation.height),
                                  display: display, viewport: viewport)
                dragPan = .zero
            }
    }

    private func clampedPan(display: CGSize, viewport: CGSize) -> CGSize {
        clampOffset(CGSize(width: pan.width + dragPan.width, height: pan.height + dragPan.height),
                    display: display, viewport: viewport)
    }

    /// Keep the image within reach: you can push each edge to the viewport edge
    /// but not drag the picture entirely out of view.
    private func clampOffset(_ offset: CGSize, display: CGSize, viewport: CGSize) -> CGSize {
        let maxX = max(0, (display.width - viewport.width) / 2)
        let maxY = max(0, (display.height - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }

    /// The size an image occupies when aspect-fit into `viewport`.
    private func fittedSize(of image: NSImage?, in viewport: CGSize) -> CGSize? {
        guard let image else { return nil }
        let px = pixelSize(of: image)
        guard px.width > 0, px.height > 0 else { return nil }
        let scale = min(viewport.width / px.width, viewport.height / px.height)
        return CGSize(width: px.width * scale, height: px.height * scale)
    }

    private func pixelSize(of image: NSImage) -> CGSize {
        var best = CGSize.zero
        for rep in image.representations {
            let size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if size.width * size.height > best.width * best.height { best = size }
        }
        return (best.width > 0 && best.height > 0) ? best : image.size
    }

    /// Full-resolution load for the current page (and the tray's disc), so 1:1
    /// zoom shows real detail. Neighbors aren't preloaded.
    private func loadCurrent() async {
        guard let page = current else { return }
        for url in [page.imageURL, page.overlayURL].compactMap({ $0 }) where images[url] == nil {
            // Boxed hand-off: NSImage is only Sendable as of macOS 14.
            let boxed = await Task.detached(priority: .userInitiated) {
                UncheckedSendableBox(NSImage(contentsOf: url))
            }.value
            if let image = boxed.value {
                images[url] = image
            }
        }
    }

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: onClose(); return nil          // Esc
            case 123: step(-1); return nil          // ←
            case 124: step(1); return nil           // →
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}
