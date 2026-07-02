import SwiftUI

/// An embossed detent pressed into a fader's chassis (POSITION center, VOLUME
/// unity). `label` renders a tiny embossed caption below the tick (VOLUME "0").
struct FaderDetent {
    let fraction: Double
    var label: String? = nil
}

/// Shared v10 fader anatomy for the footer POSITION and VOLUME pods: a 7pt
/// recessed pill rail with a cyan→orange fill, embossed detent ticks pressed
/// into the chassis, and an 11×26 vertical metal cap with a center grip line.
/// Horizontal travel; dragging anywhere positions the cap absolutely
/// (grab-and-move, like a real deck slider), matching the v10 mock.
struct FaderTrack: View {
    @Environment(\.carbon) private var theme
    let progress: Double
    var detents: [FaderDetent] = []
    /// Live absolute fraction while dragging.
    var onScrub: (Double) -> Void
    /// Drag end; falls back to `onScrub` when nil.
    var onCommit: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                // Embossed detent ticks (behind the cap — pressed into chassis).
                ForEach(detents.indices, id: \.self) { i in
                    detentMark(detents[i], width: w)
                }

                // Recessed pill rail.
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.42 : 0.12))
                    .overlay(Capsule().stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.45), lineWidth: 0.6))
                    .frame(height: 7)

                // Cyan→orange fill up to the cap.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan.opacity(0.92), theme.orange.opacity(0.88)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, w * p), height: 7)
                    .shadow(color: theme.cyan.opacity(theme.isDark ? 0.26 : 0.18), radius: 5)

                // Vertical metal cap.
                cap.offset(x: min(max(w * p - 5.5, 0), w - 11))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in onScrub(min(max(g.location.x / w, 0), 1)) }
                    .onEnded { g in (onCommit ?? onScrub)(min(max(g.location.x / w, 0), 1)) }
            )
        }
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: theme.metalHi, location: 0),
                        .init(color: theme.metal, location: 0.45),
                        .init(color: theme.metalLo, location: 1)
                    ]),
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: 11, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.6)
            )
            .overlay(gripLine)
            .shadow(color: Color.black.opacity(0.55), radius: 3, y: 3)
    }

    /// Vertical grip: a dark hairline with a light edge to its right.
    private var gripLine: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.5)
            Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1)
        }
        .frame(height: 20)
    }

    /// A 2pt-wide tick that extends 7pt above/below the rail (21pt tall) with a
    /// 1pt light edge to its right, plus an optional embossed caption below.
    private func detentMark(_ d: FaderDetent, width: CGFloat) -> some View {
        let x = width * d.fraction
        return ZStack {
            HStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.5)).frame(width: 2)
                Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1)
            }
            .frame(height: 21)

            if let label = d.label {
                Text(label)
                    .font(CarbonFont.mono(7, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .shadow(color: Color.white.opacity(0.2), radius: 0, y: 1)
                    .offset(y: 15)
            }
        }
        .offset(x: x - 1)
        .allowsHitTesting(false)
    }
}
