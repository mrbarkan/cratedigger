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

extension CarbonTheme {
    /// Lead-glyph tint for a browser row: selection ink when selected, orange
    /// when it hosts the now-playing track, otherwise muted ink.
    func rowLeadColor(selected: Bool, isPlaying: Bool) -> Color {
        if selected { return selectionInk }
        if isPlaying { return orange }
        return ink3
    }

    /// Title tint for a browser row.
    func rowTitleColor(selected: Bool) -> Color {
        selected ? selectionInk : ink
    }

    /// Trailing-meta tint for a browser row.
    func rowMetaColor(selected: Bool) -> Color {
        selected ? selectionInk.opacity(0.72) : ink3
    }
}
