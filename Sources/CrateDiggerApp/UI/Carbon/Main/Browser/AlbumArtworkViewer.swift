import AppKit
import CrateDiggerCore
import SwiftUI

/// A hosting view with no safe area. The panel is `fullSizeContentView`, so its
/// content view already spans the titlebar — but SwiftUI still insets its own
/// layout by that titlebar, which pushed the rim and its rounded corners about
/// 28pt below the glass edge and left a dead band of bare material across the
/// top. The panel draws all of its own chrome, so there is nothing up there to
/// keep clear of.
private final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

/// A small, movable, resizable panel that keeps album art on screen while the
/// user keeps working in the main window. Non-activating so clicking or dragging
/// it never steals key focus (Edit Tags etc. stay usable), floating so it stays
/// on top, titled so macOS gives free edge-resize handles. Its own ✕ pill closes
/// it, so the native window buttons are hidden. The surround is Liquid Glass on
/// macOS 26, frosted `NSVisualEffectView` before it.
public final class FloatingArtworkPanel: NSPanel {
    /// The corner radius of the panel's glass. Liquid Glass is drawn with a
    /// larger, softer curve than the old frosted plate, and the radius is a
    /// property of the material rather than something clipped over it.
    static let cornerRadius: CGFloat = 18

    /// Whether this machine gets Apple's Liquid Glass (macOS 26) or the older
    /// `NSVisualEffectView` frosting. Read by the panel to build its material
    /// and by the SwiftUI tree to decide whether to draw its own rim, so the
    /// two can never disagree about which look is on screen.
    static var usesLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

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
        // A pane of glass with no shadow reads as a flat sticker. The window is
        // non-opaque, so AppKit takes the shadow's shape from the content's
        // alpha, which the rounded glass below has already shaped.
        hasShadow = true
        minSize = NSSize(width: 320, height: 260)   // the control bar's natural width
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // The material picks its light or dark variant from the window's
        // appearance, so without this the panel follows *macOS* while the rest
        // of the app follows Appearance in preferences: dark console, pale
        // glass. Set once at open; a panel already floating when the user
        // switches mode keeps the one it was born with.
        appearance = AppearanceMode.current.nsAppearance

        // The panel used to draw its own blurred copy of the artwork under an
        // 82% black scrim, which is an opaque plate by any other name. Real
        // glass samples what is actually behind the window.
        let bounds = NSRect(origin: .zero, size: size)
        let hosting = EdgeToEdgeHostingView(rootView: content)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            // Apple's Liquid Glass. It is its own view rather than a material on
            // NSVisualEffectView, it lenses and refracts what is behind it
            // instead of just blurring, and it rounds itself — `cornerRadius` is
            // a property of the glass, so there is no mask to keep in sync and
            // no square material corner left showing under a SwiftUI clip.
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.autoresizingMask = [.width, .height]
            // Must be `contentView`: the class only promises to put *that* view
            // inside the glass, and a plain `addSubview` lands outside it.
            glass.contentView = hosting
            contentView = glass
        } else {
            // Pre-26: frosted glass, masked by hand because a behind-window blur
            // is composited by the WindowServer underneath the view tree, so a
            // SwiftUI clipShape rounds the contents and leaves the material's
            // own square corners showing.
            let frosted = NSVisualEffectView(frame: bounds)
            frosted.material = .hudWindow
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            frosted.autoresizingMask = [.width, .height]
            frosted.maskImage = Self.cornerMask(radius: Self.cornerRadius)
            frosted.addSubview(hosting)
            contentView = frosted
        }

        // Tuck into the top-right of the app window, else center on screen.
        if let ref = reference {
            let rf = ref.frame
            setFrameTopLeftPoint(NSPoint(x: rf.maxX - size.width - 24, y: rf.maxY - 24))
        } else {
            center()
        }
    }

    public override var canBecomeKey: Bool { true }

    /// A resizable rounded-rect mask for the glass. `capInsets` pins the corners
    /// at their drawn size and stretches only the middle, so one small image
    /// masks the panel at any size the user drags it to.
    private static func cornerMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The control-bar button treatment, in one place for both bars.
///
/// On macOS 26 this is Apple's own Liquid Glass button style, which supplies the
/// capsule, the material, the hover and the press — and picks a label colour
/// that stays readable over whatever the control is floating above. Before 26 it
/// is the app's `carbonHover` style over a hand-drawn capsule.
private extension View {
    @ViewBuilder
    func artworkBarButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            // Capsule so the buttons match the readouts and the zoom pill, which
            // get their surface from `BarSurface` instead. Left to itself the
            // glass style rounds to a squarer rect, and the row came out as two
            // shapes pretending to be one set.
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.carbonHover)
        }
    }
}

/// A Liquid Glass capsule usable as a SwiftUI background.
///
/// SwiftUI on macOS 26 exposes glass only as a *button* style — there is no
/// `.glassEffect` modifier in the macOS SDK — so a surface behind something that
/// isn't a button (the dim slider) has to come from AppKit.
@available(macOS 26.0, *)
private struct GlassCapsule: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

/// The surface behind a bar control that is not a button, matched to the glass
/// buttons beside it so the row reads as one set.
private struct BarSurface: ViewModifier {
    var cornerRadius: CGFloat = 17

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background(GlassCapsule(cornerRadius: cornerRadius))
        } else {
            content
                .foregroundStyle(.white.opacity(0.85))
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
    }
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
        // The full-screen viewer is a dark room whatever the app's Appearance
        // says: its backdrop is a black scrim over the whole screen. Without
        // this the window inherits a light appearance, and the two glass
        // mechanisms disagree — SwiftUI's glass buttons follow the *window*
        // and come out light, while the AppKit glass behind the readout and
        // the zoom pill samples the actual black backdrop and comes out dark,
        // so one half of the bar was pale and the other half was not.
        w.appearance = NSAppearance(named: .darkAqua)
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

    static func buildPages(_ album: Album) -> [ArtworkPage] {
        let albumFolder = album.tracks.first?.track.fileURL.deletingLastPathComponent()
        var pages = albumFolder.map { AlbumArtCatalog.pages(in: $0) } ?? []

        // Guarantee a Cover page, because this viewer opens on page one and a
        // folder holding only booklet scans or a back would otherwise open on
        // a sheet of scanned paper with no way to reach the front at all.
        //
        // A real cover file always wins: the catalog emits it as `.cover` and
        // this adds nothing. The synthetic page is the embedded tag image, and
        // it is drawn capped at its own pixel size (see `embeddedArtSide`) so
        // standing in for a missing cover can't mean a wall of upscaled pixels.
        let hasCoverPage = pages.contains { $0.kind == .cover }
        let hasEmbeddedArt = album.artworkHash != nil
            || album.tracks.contains { $0.track.artworkHash != nil }
        if !hasCoverPage, hasEmbeddedArt {
            pages.insert(ArtworkPage(kind: .cover, label: "Cover", imageURL: nil), at: 0)
        }
        // Nothing on disk and nothing in the tags: an empty page still beats an
        // empty window, and the placeholder sleeve is what it draws.
        if pages.isEmpty {
            pages = [ArtworkPage(kind: .cover, label: "Cover", imageURL: nil)]
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
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album
    /// State, not a constant: the window stays open while artwork is edited
    /// behind it, and a page list frozen at open time kept showing images that
    /// had since been moved to the Trash.
    @State private var pages: [ArtworkPage]
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
    @State private var confirmingDelete = false
    /// How far the app behind is dimmed out, 0 (clear) … 1 (black). Replaces the
    /// old two-position FOCUS toggle, which was this same value quantised to
    /// "0.55 or 0.94" — a slider says the same thing and lets you land between.
    @AppStorage("artworkBackdropDim") private var backdropDim = 0.55

    init(album: Album, pages: [ArtworkPage], startIndex: Int = 0, floating: Bool = false,
         onClose: @escaping () -> Void, onFloat: ((Int) -> Void)? = nil, onExpand: ((Int) -> Void)? = nil) {
        self.album = album
        _pages = State(initialValue: pages)
        self.floating = floating
        self.onClose = onClose
        self.onFloat = onFloat
        self.onExpand = onExpand
        _index = State(initialValue: max(0, min(startIndex, max(0, pages.count - 1))))
    }

    private var current: ArtworkPage? { pages.indices.contains(index) ? pages[index] : nil }

    /// Re-read the album folder after an artwork change. Keeps the viewer on the
    /// same page where it still exists, and drops decoded images for files that
    /// have gone so a trashed page can't be served from memory.
    private func reloadPages() {
        let rebuilt = ArtworkViewerPresenter.buildPages(album)
        let currentURL = current?.imageURL
        pages = rebuilt

        if let currentURL, let stillThere = rebuilt.firstIndex(where: { $0.imageURL == currentURL }) {
            index = stillThere
        } else {
            index = min(index, max(0, rebuilt.count - 1))
        }

        let live = Set(rebuilt.compactMap { $0.imageURL } + rebuilt.compactMap { $0.overlayURL })
        images = images.filter { live.contains($0.key) }
    }

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
        // Artwork added, removed or re-cut while this window is open.
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("CrateDiggerArtworkImported"))) { _ in
            reloadPages()
        }
    }

    private var fullscreenBody: some View {
        ZStack {
            // Left as a plain scrim on purpose. The ask was frosted glass
            // here too, and it needs the *app behind this window* blurred —
            // which means an NSVisualEffectView in `.behindWindow` mode, since
            // the viewer is its own window and `.withinWindow` has nothing to
            // sample. Both were tried; neither can be checked with the
            // self-snapshot hook (it renders the layer tree, not WindowServer's
            // compositing), and a blurred *artwork* plate here covers the app
            // rather than frosting it. Shipping a look nobody has seen is worse
            // than shipping the one that works.
            Color.black.opacity(backdropDim)
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
        // No plate here on purpose: the glass is the window's own
        // NSVisualEffectView (see `FloatingArtworkPanel`), so anything drawn
        // behind the art would sit on top of the material and hide it. This
        // view stays transparent and lets the blur through.
        .contentShape(Rectangle())
        // The rim was a cyan neon outline that lit on hover. A grabbable window
        // doesn't need to glow — the glass reads as an object, so the rim just
        // firms up under the pointer.
        //
        // Liquid Glass draws its own lit edge and specular highlight, so a
        // hand-drawn hairline on top of it reads as a second, wrong border.
        // There it is left to the material; the frosted fallback still needs one.
        .overlay {
            if !FloatingArtworkPanel.usesLiquidGlass {
                RoundedRectangle(cornerRadius: FloatingArtworkPanel.cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(floatingHovering ? 0.30 : 0.14),
                        lineWidth: 1
                    )
                    .padding(1)
                    .animation(.easeInOut(duration: 0.18), value: floatingHovering)
            }
        }
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
                    // Synthetic cover backed by the album's embedded art, capped
                    // at its own pixel size: filling the viewport with a 300 px
                    // thumbnail is exactly the wall of pixels to avoid.
                    let side = min(min(viewport.width, viewport.height), embeddedArtSide)
                    AlbumPoster(album: album)
                        .frame(width: side, height: side)
                        .onTapGesture {}
                } else if let image = page.imageURL.flatMap({ images[$0] }) {
                    zoomableImage(image, viewport: viewport)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    /// The longest edge of the album's embedded artwork, in points. Unknown
    /// dimensions fall back to a conservative 600.
    private var embeddedArtSide: CGFloat {
        let native = album.tracks
            .compactMap(\.track.artworkDimensions)
            .map { max($0.width, $0.height) }
            .max()
        return CGFloat(native ?? 600)
    }

    @ViewBuilder
    private func zoomableImage(_ image: NSImage, viewport: CGSize) -> some View {
        switch zoom {
        case .fit:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .depthShadow(color: .black.opacity(0.5), radius: 22, y: 10)
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
                    .depthShadow(color: .black.opacity(0.5), radius: 18, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control cluster (parked below the art, never overlapping it)

    /// Every control in the bar is one height and one shape, grouped by what it
    /// acts on and separated by hairlines — the same stepper-then-tools reading
    /// the floating panel's bar already had. Before this it was six differently
    /// sized pills in one undifferentiated row, with CLOSE wedged between BACK
    /// and FWD so the pager didn't read as a pager.
    private static let barHeight: CGFloat = 34
    /// The floating panel's bar, which sits under a small picture.
    private static let compactBarHeight: CGFloat = 28

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

            HStack(spacing: 6) {
                // Page through
                pillButton(label: "BACK", icon: "chevron.left") { step(-1) }
                    .disabled(pages.count <= 1)
                    .opacity(pages.count <= 1 ? 0.35 : 1)
                Text("\(index + 1) / \(pages.count)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minWidth: 52)
                    .frame(height: Self.barHeight)
                    .modifier(BarSurface(cornerRadius: Self.barHeight / 2))
                pillButton(label: "FWD", icon: "chevron.right") { step(1) }
                    .disabled(pages.count <= 1)
                    .opacity(pages.count <= 1 ? 0.35 : 1)

                barDivider

                // How it is shown
                zoomMenu()
                dimControl

                barDivider

                // What to do with this page
                iconPill("eye.slash", size: Self.barHeight) { hideCurrentPage() }
                    .disabled(!canEditCurrentPage)
                    .opacity(canEditCurrentPage ? 1 : 0.35)
                    .help("Hide this image from the viewer. The file stays put, and the ART tab shows it as Ignore.")
                iconPill("trash", size: Self.barHeight) { confirmingDelete = true }
                    .disabled(!canEditCurrentPage)
                    .opacity(canEditCurrentPage ? 1 : 0.35)
                    .help("Move this image file to the Trash")

                barDivider

                // The window itself
                iconPill("macwindow.on.rectangle", size: Self.barHeight) { onFloat?(index) }
                    .help("Pop out into a small panel that stays on top")
                pillButton(label: "CLOSE") { onClose() }
            }
            .padding(.top, 4)
        }
        .confirmationDialog("Move “\(current?.imageURL?.lastPathComponent ?? "")” to the Trash?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { deleteCurrentPage() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The file leaves the album folder. You can put it back from the Trash.")
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }

    /// How far the app behind the viewer is dimmed out. Was a FOCUS toggle with
    /// two hard-coded stops; artwork on a light backdrop and artwork on black are
    /// different pictures, so this is a knob rather than a switch.
    private var dimControl: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .bold))
            Slider(value: $backdropDim, in: 0...1)
                .controlSize(.mini)
                .frame(width: 88)
                .tint(.white.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .frame(height: Self.barHeight)
        .modifier(BarSurface())
        .help("Dim the app behind the artwork")
    }

    /// The zoom control. `compact` sizes it for the floating panel's bar.
    ///
    /// `.menuStyle(.button)` rather than `.borderlessButton`: the borderless
    /// style draws a bezel of its own, which is why this control used to be a
    /// short rounded rectangle sitting among capsules with a second, hand-added
    /// capsule showing behind it. As a button menu it takes the same style as
    /// every other pill and cannot drift out of step again.
    private func zoomMenu(compact: Bool = false) -> some View {
        let height = compact ? Self.compactBarHeight : Self.barHeight
        return Menu {
            Button("Fit to Screen") { setZoom(.fit) }
            Button("50%") { setZoom(.scale(0.5)) }
            Button("100%") { setZoom(.scale(1.0)) }
            Button("200%") { setZoom(.scale(2.0)) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                // Fixed width: FIT, 50% and 200% are different lengths, and
                // letting the pill resize shuffled every control beside it each
                // time the zoom changed.
                Text(zoom.label)
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(1.5)
                    .frame(width: compact ? 34 : 38, alignment: .leading)
            }
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: height)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // The surface is applied here, not through the glass *button* style the
        // pills use. AppKit re-hosts a Menu's label, and the glass style's
        // chrome does not survive that: in the full-screen bar the control kept
        // its layout space and drew nothing at all. This is the same explicit
        // surface the dim slider uses, which does survive.
        .modifier(BarSurface(cornerRadius: height / 2))
    }

    private func pillButton(label: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barLabel {
                HStack(spacing: 6) {
                    if let icon, icon == "chevron.left" { Image(systemName: icon) }
                    Text(label).font(CarbonFont.mono(9.5, weight: .bold)).tracking(1.5)
                    if let icon, icon == "chevron.right" { Image(systemName: icon) }
                }
            }
        }
        .artworkBarButtonStyle()
    }

    /// One surface for every control in both bars.
    ///
    /// On macOS 26 the shape, the fill, the hover and the press all come from
    /// Apple's glass button style, so the label is only content and padding —
    /// and it deliberately does not force white, because glass picks a label
    /// colour that stays legible against whatever it is floating over. Before
    /// 26 it stays the hand-drawn capsule this viewer shipped with.
    @ViewBuilder
    private func barLabel<L: View>(compact: Bool = false, @ViewBuilder _ label: () -> L) -> some View {
        let height = compact ? Self.compactBarHeight : Self.barHeight
        if FloatingArtworkPanel.usesLiquidGlass {
            // Less padding than the fallback on purpose: the glass style adds
            // its own insets, and stacking the two made every control noticeably
            // fatter than the bar it lives in.
            label()
                .padding(.horizontal, compact ? 2 : 8)
                .frame(height: height)
        } else {
            label()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, compact ? 12 : 18)
                .frame(height: height)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
    }

    // MARK: - This page

    private var albumFolder: URL? {
        album.tracks.first?.track.fileURL.deletingLastPathComponent()
    }

    /// The synthetic cover has no file behind it, and the tray page is two files
    /// composited — neither is one image you can hide or throw away.
    private var canEditCurrentPage: Bool {
        current?.imageURL != nil && current?.kind != .tray
    }

    /// Take the page out of the viewer without touching the file: `.ignore` is
    /// the role the catalog already reads to skip an image, and it is what the
    /// ART tab's picker calls "Ignore" — so hiding here and hiding there are the
    /// same edit rather than two ideas.
    private func hideCurrentPage() {
        guard let url = current?.imageURL, let folder = albumFolder else { return }
        var manifest = ArtworkManifest.load(from: folder) ?? ArtworkManifest()
        manifest.roles[url.lastPathComponent] = .ignore
        do {
            try manifest.save(to: folder)
        } catch {
            model.appAlert = .error(
                title: "Couldn't hide that image",
                message: "Writing to “\(folder.lastPathComponent)” failed: \(error.localizedDescription)"
            )
            return
        }
        artworkFolderChanged(folder)
    }

    private func deleteCurrentPage() {
        guard let url = current?.imageURL, let folder = albumFolder else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            model.appAlert = .error(
                title: "Couldn't move that image to the Trash",
                message: "“\(url.lastPathComponent)” stayed put: \(error.localizedDescription)"
            )
            return
        }
        var manifest = ArtworkManifest.load(from: folder) ?? ArtworkManifest()
        let name = url.lastPathComponent
        manifest.roles[name] = nil
        manifest.discSides?[name] = nil
        manifest.discNumbers?[name] = nil
        try? manifest.save(to: folder)
        artworkFolderChanged(folder)
    }

    /// This folder's art just changed on disk. The notification is the same one
    /// the ART tab posts on SAVE, and this view listens for it — so the viewer
    /// rebuilds its own pages through exactly one path.
    private func artworkFolderChanged(_ folder: URL) {
        model.indexDiskCache.invalidate(
            albumFolderPath: folder.path,
            filePaths: album.tracks.map { $0.track.fileURL.path }
        )
        model.refreshLibrary()
        NotificationCenter.default.post(
            name: NSNotification.Name("CrateDiggerArtworkImported"), object: nil
        )
    }

    // MARK: - Floating panel controls (compact, pinned at the bottom)

    /// One bar, centred under the art: the page label sits *between* its arrows so
    /// they read as a stepper, then zoom / expand / close behind a hairline. The bar
    /// hugs its contents — the old full-width slab with a hole in the middle read as
    /// a second window pasted under the picture.
    ///
    /// On macOS 26 the controls are Liquid Glass and sit directly on the panel's
    /// own glass; before that the bar keeps a dark slab, because white glyphs
    /// would otherwise sit straight on light artwork.
    private var floatingControls: some View {
        HStack(spacing: 6) {
            iconPill("chevron.left") { step(-1) }.disabled(pages.count <= 1).opacity(pages.count <= 1 ? 0.35 : 1)

            // The readout is a label, not a button, but it sits *inside* the
            // stepper — left bare on the panel's glass it read as a hole
            // between two controls rather than the middle of one.
            Text(current?.label.uppercased() ?? "—")
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(theme.orange)
                .lineLimit(1)
                .frame(minWidth: 62)          // steady width so paging doesn't shuffle the row
                .multilineTextAlignment(.center)
                .frame(height: Self.compactBarHeight)
                .modifier(BarSurface(cornerRadius: Self.compactBarHeight / 2))

            iconPill("chevron.right") { step(1) }.disabled(pages.count <= 1).opacity(pages.count <= 1 ? 0.35 : 1)

            Rectangle()
                // Semantic, not white: this hairline sits on glass that goes
                // light or dark with the artwork behind it.
                .fill(.separator)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            zoomMenu(compact: true)
            iconPill("arrow.up.left.and.arrow.down.right") { onExpand?(index) }   // dock back to full-screen
            iconPill("xmark") { onClose() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The dark slab was there so white glyphs would not sit straight on
        // light artwork. Glass controls carry their own legible surface, so on
        // macOS 26 the slab would just be a second, heavier shape on top of the
        // panel's glass; before 26 it still earns its place.
        .background {
            if !FloatingArtworkPanel.usesLiquidGlass {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.72))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .fixedSize()
    }

    /// A square-ish icon control. Same surface as `pillButton`, sized by glyph
    /// rather than by text so the two read as one family.
    private func iconPill(_ systemName: String, size: CGFloat = 28, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barLabel(compact: size <= Self.compactBarHeight) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .bold))
                    .frame(minWidth: size - 12)
            }
        }
        .artworkBarButtonStyle()
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

    /// Turning a page re-centres the image but keeps the zoom: comparing the
    /// same corner of two scans is the whole reason to be at 100 %, and dropping
    /// back to FIT on every step made that impossible.
    private func resetView() {
        pan = .zero
        dragPan = .zero
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
            // The Trash confirmation owns the keyboard while it is up: Esc must
            // cancel the dialog, not close the viewer out from under it.
            guard !confirmingDelete else { return event }
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
