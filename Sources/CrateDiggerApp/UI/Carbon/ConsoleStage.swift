import AppKit
import CoreImage
import CrateDiggerCore
import SwiftUI

/// How the console is arranged, as distinct from which layout the app is in.
///
/// `LibraryViewModel.playerLayout` flips the moment a fold is asked for. The
/// arrangement follows it under `MainWindowController`'s direction, so the
/// full console can be built before anything moves and removed only after it
/// has faded. Its own object rather than view-model state: only the stage
/// watches it, so driving a fold does not invalidate every view that observes
/// the model.
@MainActor
final class ConsoleStage: ObservableObject {
    /// Where the display and the transport sit, and which surround shows.
    @Published var arrangement: PlayerLayout
    /// Whether the full console's surround (brand block, switcher, browser)
    /// exists. True in full, and across a fold or unfold while it fades.
    @Published var mountsFullConsole: Bool
    /// The compact window's size while the window is travelling to or from
    /// it. The hosting view is held at the full console's size for the trip
    /// (`ConsoleContainerViewController`), so the compact arrangement cannot
    /// read its own size from the view. Nil at rest.
    @Published var heldCompactSize: CGSize?
    init(layout: PlayerLayout) {
        arrangement = layout
        mountsFullConsole = layout == .full
    }
}

/// Where the two pieces both layouts share sit in each of them: the display
/// and the transport. Rects are in the console's content space (inside the
/// chassis insets, origin top-left, y down).
enum ConsoleSlots {
    static func display(in layout: PlayerLayout, size: CGSize, geometry: CarbonGeometry) -> CGRect {
        switch layout {
        case .full:
            let x = geometry.brandWidth + geometry.mainGap
            let width = size.width - x - geometry.mainGap - geometry.viewSwitchWidth
            return CGRect(x: x, y: 0, width: max(0, width), height: geometry.headerHeight)
        case .compact:
            let x = CompactDeckMetrics(geometry: geometry).artSide + geometry.mainGap
            return CGRect(x: x, y: 0, width: max(0, size.width - x), height: geometry.headerHeight)
        }
    }

    static func transport(in layout: PlayerLayout, size: CGSize, geometry: CarbonGeometry) -> CGRect {
        let y = max(geometry.headerHeight + geometry.chassisRowGap, size.height - geometry.footerHeight)
        switch layout {
        case .full:
            return CGRect(x: 0, y: y, width: size.width, height: geometry.footerHeight)
        case .compact:
            let display = display(in: .compact, size: size, geometry: geometry)
            return CGRect(x: display.minX, y: y, width: display.width, height: geometry.footerHeight)
        }
    }
}

/// The console's content: one display and one transport that both layouts
/// share, and around them either the full console's surround or the compact
/// player's art column.
///
/// They are the same views in both layouts, so the display keeps what it is
/// showing across a fold. The fold itself goes out of focus and back: a
/// blurred picture of the console is laid over it
/// (`ConsoleContainerViewController.raiseVeil`), the arrangement is swapped
/// underneath as a cut, the window travels, and the picture clears on the
/// new arrangement at its final size.
///
/// Nothing here animates; see the steps in `MainWindowController` for what
/// was tried and measured before this.
struct ConsoleStageView: View {
    @ObservedObject var stage: ConsoleStage
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        GeometryReader { proxy in
            let live = proxy.size
            let compact = stage.arrangement == .compact
            let compactSize = stage.heldCompactSize.map(contentSize(ofWindow:)) ?? live
            let size = compact ? compactSize : live
            let display = ConsoleSlots.display(in: stage.arrangement, size: size, geometry: geometry)
            let transport = ConsoleSlots.transport(in: stage.arrangement, size: size, geometry: geometry)

            // Everything hangs from the top centre: the window travels with
            // its content pinned there, so a slot is an offset from that
            // point whatever size the window has reached.
            ZStack(alignment: .top) {
                if stage.mountsFullConsole {
                    FullConsoleSurround()
                        .frame(width: live.width, height: live.height)
                        .allowsHitTesting(!compact)
                    // Mounted before an unfold and until a fold lands, and
                    // hidden in compact by a cover rather than by opacity:
                    // under a cover it is still painted, so the unfold's
                    // first frame has nothing left to draw.
                    theme.chassis
                        .frame(width: live.width, height: live.height)
                        .opacity(compact ? 1 : 0)
                        .allowsHitTesting(false)
                }
                if compact {
                    CompactArtColumn()
                        .frame(width: compactSize.width, height: compactSize.height, alignment: .topLeading)
                }
                OLEDDisplay()
                    .environment(\.oledScreenOverride, compact ? .nowPlaying : nil)
                    .frame(width: display.width, height: display.height)
                    .offset(x: display.midX - size.width / 2, y: display.minY)
                FooterShell()
                    .frame(width: transport.width, height: transport.height)
                    .offset(x: transport.midX - size.width / 2, y: transport.minY)
            }
            .frame(width: live.width, height: live.height, alignment: .top)
        }
    }

    /// A window's frame size less the chassis insets this view sits inside.
    private func contentSize(ofWindow size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width - 2 * geometry.chassisInsetH),
               height: max(0, size.height - 2 * geometry.chassisInsetV))
    }
}

/// The full console around the display and the transport: the brand block
/// and the VIEW/THEME/EQ switcher either side of the display's slot, and the
/// three panes between the header row and the transport's slot.
///
/// Header grid: brand 156 · display flex · switcher 110, gap 12 (the brand
/// column is a fixed width, not the Sources pane's).
private struct FullConsoleSurround: View {
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        VStack(spacing: geometry.chassisRowGap) {
            HStack(spacing: geometry.mainGap) {
                BrandBlock()
                    .frame(width: geometry.brandWidth, alignment: .leading)
                Color.clear
                    .allowsHitTesting(false)
                ViewSwitcherColumn()
                    .frame(width: geometry.viewSwitchWidth)
            }
            .frame(height: geometry.headerHeight)
            MainShell()
                .frame(maxHeight: .infinity)
            Color.clear
                .frame(height: geometry.footerHeight)
                .allowsHitTesting(false)
        }
    }
}

/// The window's content view controller: a plain container around the
/// SwiftUI hosting view, so the hosting view can be held at one size while
/// the window travels.
///
/// A window resizes its content view on every frame of an animated resize,
/// and SwiftUI answers each one by laying the console out and redrawing its
/// panels at the new size (measured: 30 to 75 ms a frame on the way to the
/// full console, which is what made the unfold stutter). Held, the console
/// is laid out once at the full size, pinned to the window's top centre, and
/// the window opens or closes over it.
///
/// It also carries the fold's veil: a blurred still of the console, laid
/// over it while the window travels. A resizing window with the live console
/// showing gets 12 to 20 frames out of the window server; one picture over
/// it travels at full rate, and stretches with the window for free.
final class ConsoleContainerViewController: NSViewController {
    private let hosted: NSViewController
    private let veilView = VeilView()
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])

    init(hosting hosted: NSViewController) {
        self.hosted = hosted
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: WindowFramePlanner.targetSize))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true     // the veil's snapshot renders this layer
        addChild(hosted)
        hosted.view.frame = container.bounds
        hosted.view.autoresizingMask = [.width, .height]
        container.addSubview(hosted.view)
        veilView.frame = container.bounds
        veilView.autoresizingMask = [.width, .height]
        veilView.wantsLayer = true
        veilView.layer?.contentsGravity = .resize
        veilView.layer?.masksToBounds = true
        veilView.layer?.cornerCurve = .continuous
        veilView.isHidden = true
        container.addSubview(veilView)
        view = container
    }

    // MARK: Veil

    var isVeilRaised: Bool { !veilView.isHidden }

    /// Lays a blurred picture of the console as it looks now over it,
    /// fading up over `duration`: the console going out of focus.
    /// `fallback` is what the veil shows if the picture cannot be made.
    func raiseVeil(cornerRadius: CGFloat, fallback: NSColor, duration: TimeInterval) {
        guard let layer = veilView.layer else { return }
        let picture = isVeilRaised ? nil : blurredSnapshot()
        // Raised again mid-fold (a second toggle): keep the picture it has.
        if !isVeilRaised {
            layer.contents = picture
            layer.backgroundColor = picture == nil ? fallback.cgColor : nil
            veilView.alphaValue = 0
            veilView.isHidden = false
        }
        layer.cornerRadius = cornerRadius
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            veilView.animator().alphaValue = 1
        }
    }

    /// Clears the veil over `duration`: the console coming back into focus.
    func lowerVeil(duration: TimeInterval) {
        guard isVeilRaised else { return }
        veilGeneration += 1
        let generation = veilGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            veilView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Raised again before this finished: it is no longer ours to hide.
            guard let self, self.veilGeneration == generation, self.veilView.alphaValue == 0 else { return }
            self.veilView.isHidden = true
            self.veilView.layer?.contents = nil
        })
    }

    private var veilGeneration = 0

    /// A blurred picture of what the window shows, small: a quarter of the
    /// points each way. The blur hides the difference, and it keeps drawing
    /// the picture to a few milliseconds.
    private func blurredSnapshot() -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = Self.snapshotScale
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let sharp = context.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp)
        // Clamped first, so the blur has the picture's own edge to read
        // past it instead of fading to clear.
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Self.blurRadius * scale)
            .cropped(to: input.extent)
        return imageContext.createCGImage(blurred, from: input.extent)
    }

    private static let snapshotScale: CGFloat = 0.25
    /// In points of the console.
    private static let blurRadius: CGFloat = 22

    /// Clicks pass through to the console; the veil is a picture.
    private final class VeilView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Holds the hosted view at `size`, pinned to the container's top centre,
    /// whatever size the window passes through.
    func hold(size: CGSize) {
        let bounds = view.bounds
        // Fixed size, top edge fixed, centred: only the margins flex.
        hosted.view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        hosted.view.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The hosted view follows the window again.
    func release() {
        hosted.view.autoresizingMask = [.width, .height]
        hosted.view.frame = view.bounds
    }
}
