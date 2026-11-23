import AppKit
import CrateDiggerCore
import ImageIO
import SwiftUI

/// Stops a click-drag inside a control from moving the borderless window
/// (the rest of the panel stays draggable via `isMovableByWindowBackground`).
struct WindowDragGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Drags the window from anywhere a control hasn't claimed the mouse. Controls
/// keep their own clicks and drags (child gestures win), rows keep `.draggable`.
/// Below macOS 15 the window falls back to `isMovableByWindowBackground`.
struct WindowBackgroundDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            // Activation events: the floating player drags on the first click
            // even while another app is in front.
            content.gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

/// A context menu whose items are built when the menu is asked for, not each
/// time its row is drawn.
///
/// `contextMenu`'s builder runs with the row's body, so anything it computes
/// is paid per visible row on every redraw. The browser's menus resolve
/// "which tracks does this row mean", a pass over the whole source: with 8k
/// tracks that was ~60 ms per row, and a single click redrew every visible
/// row (measured: 1.2 s of a selection in the value columns, 0.7 s in the
/// track column). Wrapped in a view, the builder only runs when SwiftUI
/// resolves the menu itself.
private struct DeferredMenuItems<Items: View>: View {
    let items: () -> Items
    var body: some View { items() }
}

extension View {
    /// `contextMenu`, for a menu that is expensive to build. See
    /// `DeferredMenuItems`.
    func lazyContextMenu<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        contextMenu { DeferredMenuItems(items: items) }
    }
}

/// CRT-style horizontal scan-line texture: a 1px line every `spacing` points at
/// the given white `opacity`. Never hit-tests.
struct Scanlines: View {
    var opacity: Double
    var spacing: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                let line = Path(CGRect(x: 0, y: y, width: size.width, height: 1))
                context.fill(line, with: .color(Color.white.opacity(opacity)))
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Overlays a `Scanlines` texture.
    func scanlines(opacity: Double, spacing: CGFloat = 3) -> some View {
        overlay(Scanlines(opacity: opacity, spacing: spacing))
    }
}

/// The Carbon "selected row" treatment: a calm, flat cool fill that reads like a
/// backlit recessed slot, with a leading LED accent bar (the "you are here" cue)
/// and a soft top-lit rim for depth. Replaces the old diagonal indigo→cyan
/// gradient, which fought the content. Shared by the browser columns and the
/// Sources sidebar so selection looks identical everywhere; selection stays cool
/// while playback stays orange (the ▸ marker), keeping the two states distinct.
/// `cornerRadius` is 0 for full-bleed column rows, 6 for the sidebar's pills.
struct CarbonSelectionSlot: View {
    @Environment(\.carbon) private var theme
    var cornerRadius: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Selection is lit by its *own* three tokens, not by the accents. The
        // shape is the same either way — an LED at the leading edge and its
        // light falling off across the row — and each theme says what colour
        // that light is: the built-in dark console keeps its cool cyan-on-
        // indigo, light keeps the warm lamp and orange spread. Reading `cyan`
        // and `orange` here made every selected row in the app move whenever
        // the accent was retinted.
        let ledCore = theme.selectionLedCore
        let ledGlow = theme.selectionGlow
        let spread  = theme.selectionSpread
        let ledFill = LinearGradient(
            colors: [
                spread.opacity(theme.isDark ? 0.90 : 0.85),
                Color.clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        shape
            .fill(ledFill)
            .overlay(
                // Top-lit rim that also fades left→right, tracking the light.
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 1
                )
            )
            .clipShape(shape)
            // Leading LED — overlaid *after* the clip so its glow spills a little
            // past the slot edge (a lit bulb, not a painted stripe).
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(ledCore)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .shadow(color: ledGlow.opacity(0.9), radius: 5)
                    .shadow(color: ledCore.opacity(0.55), radius: 10)
            }
    }
}

/// Loads a downsampled thumbnail for an on-disk image via ImageIO, off the main
/// actor. Shared by the inspector poster, the artwork inspector grid, and the
/// gallery cover cells (which differ only in the max pixel size they request).
func loadThumbnail(url: URL, maxPixelSize: Int) async -> NSImage? {
    let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }.value

    guard let cgImage else { return nil }
    return NSImage(cgImage: cgImage, size: .zero)
}

/// A cast shadow's geometry, in `.shadow(color:radius:x:y:)`'s terms. The
/// colour is the caller's and never changes, so it is not part of the rule.
struct CastShadow: Equatable {
    var radius: CGFloat
    var x: CGFloat
    var y: CGFloat
}

/// Which cast shadow a part and a piece of content get in each interface
/// style, kept apart from the modifiers so the decisions are testable.
///
/// A *part* is the console itself: the case, a panel, a well, a key, a cap, a
/// fader, a floating window's own chrome. *Content* is what the console holds
/// or shows: album art, an artist photo, a booklet page, an artwork or radio
/// thumbnail, the display glass, or a picture of any of those.
enum CastShadowRule {
    /// A part's shadow follows the style. Real Hardware casts what was asked
    /// unless the FLAT switch is on (`castsShadows` false); Flat Hardware a
    /// short contact shadow; Soft Blocks and Sticker none (Sticker's hard
    /// shadow is the slab's own, not a cast one).
    static func part(_ asked: CastShadow, style: InterfaceStyle, castsShadows: Bool) -> CastShadow? {
        if style.honoursFlatSwitch && !castsShadows { return nil }
        switch style {
        case .hardware:
            return asked
        case .flatHardware:
            return CastShadow(radius: min(asked.radius, 6) * 0.45, x: asked.x * 0.5, y: min(asked.y, 4) * 0.6)
        case .softBlocks, .sticker:
            return nil
        }
    }

    /// Content keeps its shadow in every style, exactly as asked. Only Real
    /// Hardware's FLAT switch takes it away.
    static func content(_ asked: CastShadow, style: InterfaceStyle, castsShadows: Bool) -> CastShadow? {
        style.castsContentShadows(flatSwitchOn: !castsShadows) ? asked : nil
    }
}

/// Cast shadows: the shadow that says one surface sits above another.
///
/// Every panel, key, dome and album cover in the interface casts its shadow
/// through one of these rather than calling `.shadow` directly, so a theme can switch
/// the whole lot off (`effects.flat`, Real Hardware only) and get a
/// printed-looking console instead of a moulded one, and an interface style can
/// decide its parts' shadows. Emission — a lit annunciator, a phosphor halo, an
/// LED glow — is not depth and keeps its own `.shadow`: a flat theme still
/// lights up.
///
/// Same argument labels as `.shadow(color:radius:x:y:)`, so a call site only
/// changes name. Pick by what casts it (see `CastShadowRule`):
/// - `depthShadow` for a part of the console: follows the interface style.
/// - `contentShadow` for content and the display: the same in every style.
extension View {
    func depthShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(CastShadowModifier(kind: .part, color: color, asked: CastShadow(radius: radius, x: x, y: y)))
    }

    func contentShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(CastShadowModifier(kind: .content, color: color, asked: CastShadow(radius: radius, x: x, y: y)))
    }
}

private struct CastShadowModifier: ViewModifier {
    enum Kind { case part, content }

    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    let kind: Kind
    let color: Color
    let asked: CastShadow

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            content
        }
    }

    private var shadow: CastShadow? {
        switch kind {
        case .part: return CastShadowRule.part(asked, style: style, castsShadows: theme.castsShadows)
        case .content: return CastShadowRule.content(asked, style: style, castsShadows: theme.castsShadows)
        }
    }
}

extension CarbonTheme {
    /// Ink for text sitting on a selection slot (`CarbonSelectionSlot`): white on
    /// the dark-mode indigo fill; the primary dark ink on the light-mode orange
    /// fill, which fades to a light background — white would drop out on the far
    /// side. Text on an accent-filled key (the Patch Bay, a selected key)
    /// prints in `accentInk` instead.
    var slotInk: Color { isDark ? selectionInk : ink }

    /// Lead-glyph tint for a browser row: selection ink when selected, orange
    /// when it hosts the now-playing track, otherwise muted ink.
    func rowLeadColor(selected: Bool, isPlaying: Bool) -> Color {
        if selected { return slotInk }
        if isPlaying { return orange }
        return ink3
    }

    /// Title tint for a browser row.
    func rowTitleColor(selected: Bool) -> Color {
        selected ? slotInk : ink
    }

    /// Trailing-meta tint for a browser row.
    func rowMetaColor(selected: Bool) -> Color {
        selected ? slotInk.opacity(0.72) : ink3
    }
}
