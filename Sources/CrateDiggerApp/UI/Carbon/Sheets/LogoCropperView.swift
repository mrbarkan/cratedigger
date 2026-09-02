import AppKit
import CrateDiggerCore
import SwiftUI

/// The header row at 1:1, on the theme's own chassis: "CrateDigger" where it
/// sits in the app, and the logo slot opposite showing whatever `slot`
/// draws — the shipped logo, or the crop being framed. What you see here is
/// what the header will show, at the size it will show it.
struct LogoHeaderPreview<Slot: View>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @ViewBuilder var slot: () -> Slot

    var body: some View {
        HStack(spacing: 8) {
            Text("CrateDigger")
                .font(CarbonFont.sans(14, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            slot()
                .frame(width: geometry.viewSwitchWidth, height: HeaderKeyMetrics.brandRowHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.chassis))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.hair))
    }
}

/// A crop drawn into whatever frame it's given — the viewport, the 1:1 slot,
/// nothing else knows how. Sizes come from `LogoCropPlanner`, the same call
/// the export makes.
struct LogoCropCanvas: View {
    let image: NSImage
    let crop: LogoCrop

    var body: some View {
        GeometryReader { proxy in
            let rect = LogoCropPlanner.imageRect(image: image.size, in: proxy.size, crop: crop)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

/// The crop table: the source image in a viewport the shape of the header
/// slot, dragged into place and zoomed with the fader (or a pinch), then
/// APPLY renders it. FIT shows the whole image, FILL covers the strip;
/// double-click is FIT.
struct LogoCropperView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    let image: NSImage
    @Binding var crop: LogoCrop
    let onApply: () -> Void
    let onCancel: () -> Void

    @State private var dragOrigin: CGSize?
    @State private var pinchOrigin: CGFloat?

    private var slot: CGSize {
        CGSize(width: geometry.viewSwitchWidth, height: HeaderKeyMetrics.brandRowHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            viewport
            zoomRow
            HStack(spacing: 6) {
                KeyButton(action: { set(.fit) }) { Text("FIT") }
                    .frame(width: 44, height: 20)
                    .carbonTip("Show the whole image inside the slot.")
                KeyButton(action: { set(LogoCrop(zoom: fillZoom)) }) { Text("FILL") }
                    .frame(width: 44, height: 20)
                    .carbonTip("Cover the slot edge to edge, cropping whatever doesn't fit.")
                Spacer(minLength: 4)
                KeyButton(action: onCancel) { Text("CANCEL") }
                    .frame(width: 60, height: 20)
                KeyButton(style: .glowingFilled, action: onApply) { Text("APPLY") }
                    .frame(width: 60, height: 20)
                    .carbonTip("Render this framing into the theme as its logo.")
            }
        }
    }

    // MARK: - Viewport

    private var viewport: some View {
        GeometryReader { proxy in
            let frame = proxy.size
            LogoCropCanvas(image: image, crop: crop)
                .contentShape(Rectangle())
                // The panel is `isMovableByWindowBackground`; without this
                // the window takes the drag and the image never moves.
                .background(WindowDragGuard())
                .gesture(drag(in: frame))
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { set(.fit) }
        }
        .aspectRatio(slot.width / slot.height, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.chassis)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            // A dashed hairline says "this edge is the slot's edge" without
            // pretending to be part of the picture.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .carbonTip("Drag to move the image, pinch or use the fader to size it. Double-click to fit.")
    }

    private func drag(in frame: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let origin = dragOrigin ?? crop.offset
                dragOrigin = origin
                set(LogoCrop(
                    zoom: crop.zoom,
                    offset: CGSize(
                        width: origin.width + value.translation.width / max(frame.width, 1),
                        height: origin.height + value.translation.height / max(frame.height, 1)
                    )
                ))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                let origin = pinchOrigin ?? crop.zoom
                pinchOrigin = origin
                set(LogoCrop(zoom: origin * magnification, offset: crop.offset))
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    // MARK: - Zoom

    /// The fader runs the zoom range on a log scale, so a nudge near FIT is
    /// as fine as one near the top. It reads in percent of FIT: 100% is the
    /// whole image shown, the FILL detent is where it covers the slot. The
    /// image's own pixel size never enters into it — the slot is 20pt tall,
    /// so every logo is scaled to it, and the 1:1 row above is the truth.
    private var zoomFraction: Double { fraction(ofZoom: crop.zoom) }

    private func zoom(at fraction: Double) -> CGFloat {
        let range = LogoCrop.zoomRange
        return range.lowerBound * pow(range.upperBound / range.lowerBound, CGFloat(min(max(fraction, 0), 1)))
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Text("SIZE")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink4)
                .frame(width: 30, alignment: .leading)
            FaderTrack(
                progress: zoomFraction,
                fillColor: theme.orange,
                detents: detents,
                onScrub: { set(LogoCrop(zoom: zoom(at: $0), offset: crop.offset)) }
            )
            .frame(height: 26)
            .background(WindowDragGuard())
            Text("\(Int((crop.zoom * 100).rounded()))%")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .foregroundStyle(theme.ink3)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
                .carbonTip("100% shows the whole image; FILL is where it covers the slot edge to edge.")
        }
    }

    private var fillZoom: CGFloat {
        LogoCropPlanner.fillZoom(image: image.size, in: slot)
    }

    /// FIT and FILL are the same place for an image already the slot's
    /// shape (a logo being re-adjusted, say), and two labels on one tick
    /// print over each other.
    private var detents: [FaderDetent] {
        var detents = [FaderDetent(fraction: fraction(ofZoom: 1), label: "FIT")]
        if abs(fillZoom - 1) > 0.03 {
            detents.append(FaderDetent(fraction: fraction(ofZoom: fillZoom), label: "FILL"))
        }
        return detents
    }

    private func fraction(ofZoom zoom: CGFloat) -> Double {
        let range = LogoCrop.zoomRange
        return Double(log(zoom / range.lowerBound) / log(range.upperBound / range.lowerBound))
    }

    /// Every write goes through the planner's clamp, so the crop on screen
    /// is always one the export can honour.
    private func set(_ proposed: LogoCrop) {
        crop = LogoCropPlanner.clamped(proposed, image: image.size, in: slot)
    }
}
