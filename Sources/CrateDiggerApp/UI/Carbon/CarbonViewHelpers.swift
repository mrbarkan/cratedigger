import AppKit
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

/// A *depth* shadow: the cast shadow that says one surface sits above another.
///
/// Every panel, key, dome and album cover in the interface draws its through
/// here rather than calling `.shadow` directly, so a theme can switch the whole
/// lot off (`effects.flat`) and get a printed-looking console instead of a
/// moulded one. Emission — a lit annunciator, a phosphor halo, an LED glow —
/// is not depth and keeps its own `.shadow`: a flat theme still lights up.
///
/// Same argument labels as `.shadow(color:radius:x:y:)`, so a call site only
/// changes name.
extension View {
    func depthShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(DepthShadow(color: color, radius: radius, x: x, y: y))
    }
}

private struct DepthShadow: ViewModifier {
    @Environment(\.carbon) private var theme
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.castsShadows {
            content.shadow(color: color, radius: radius, x: x, y: y)
        } else {
            content
        }
    }
}

extension CarbonTheme {
    /// Ink for text sitting on a selection slot (`CarbonSelectionSlot`): white on
    /// the dark-mode indigo fill; the primary dark ink on the light-mode orange
    /// fill, which fades to a light background — white would drop out on the far
    /// side. Distinct from `selectionInk` (kept white for saturated-orange
    /// contexts like the patch bay and LEDs).
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
