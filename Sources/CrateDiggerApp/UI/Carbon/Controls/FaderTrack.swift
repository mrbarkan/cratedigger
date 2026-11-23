import CrateDiggerCore
import SwiftUI

/// A fader's measures in a style other than Real Hardware, shared by the
/// footer faders and the EQ editor's.
enum FaderMetrics {
    /// The rail's lit bottom lip (Flat Hardware) or hard shadow (Sticker).
    static let styledRailDepth: CGFloat = 1.5
    /// Sticker's inner outline on a rail.
    static let styledRailOutline: CGFloat = 1
    /// The cap's base band (Flat Hardware) or hard shadow (Sticker).
    static let styledCapDepth: CGFloat = 2
    /// Sticker's inner outline on a cap.
    static let styledCapOutline: CGFloat = 1.5
}

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
///
/// In a style other than Real Hardware the rail is a well cut into the shelf
/// and the cap a key, both the style's `StyledSlab`. A fader is dragged, not
/// pressed, so the cap never answers a press. The lit fill is a readout and
/// is the same in every style, as are the frame and the drag area.
struct FaderTrack: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    let progress: Double
    /// Solid rail colour (POSITION). Left nil, the rail wears the cyan→meter
    /// ramp (VOLUME; the high end is `meterHot`), *revealed* through a mask
    /// rather than squeezed into the
    /// filled width — so a given colour always sits at the same point on the
    /// travel, like a printed scale.
    var fillColor: Color? = nil
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

                rail

                // Fill up to the cap.
                // The fill is a light, not paint: a tight bloom hugging the
                // tube and a wider, fainter one spilling onto the shelf.
                Group {
                    if let fillColor {
                        Capsule().fill(fillColor)
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [theme.cyan, theme.meterHot],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }
                .frame(width: w, height: 5)
                .overlay(Capsule().fill(Color.white.opacity(0.22)).frame(height: 1.5).offset(y: -1.2))
                .mask(alignment: .leading) {
                    Capsule().frame(width: max(2, w * p), height: 5)
                }
                .shadow(color: (fillColor ?? theme.cyan).opacity(theme.isDark ? 0.9 : 0.55), radius: 2)
                .shadow(color: (fillColor ?? theme.meterHot).opacity(theme.isDark ? 0.45 : 0.28), radius: 8)

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

    @ViewBuilder
    private var rail: some View {
        if style == .hardware {
            realRail
        } else {
            // A slot cut into the shelf, in this style, in the same dark.
            StyledSlab(shape: Capsule(), fill: Color.black.opacity(theme.isDark ? 0.62 : 0.30),
                       depth: FaderMetrics.styledRailDepth, sunken: true,
                       outline: FaderMetrics.styledRailOutline)
                .frame(height: 7)
        }
    }

    /// Recessed pill rail: a dark slot cut into the shelf, with the inner
    /// bevel a milled groove has — shadow along its top wall, light catching
    /// its bottom lip.
    private var realRail: some View {
        Capsule()
            .fill(Color.black.opacity(theme.isDark ? 0.62 : 0.30))
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(theme.isDark ? 0.9 : 0.55), lineWidth: 2.5)
                    .blur(radius: 1.6)
                    .offset(y: 1.4)
                    .mask(Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(theme.isDark ? 0.14 : 0.5), lineWidth: 1)
                    .blur(radius: 0.6)
                    .offset(y: -0.8)
                    .mask(Capsule())
            )
            .overlay(Capsule().stroke(Color.white.opacity(theme.isDark ? 0.10 : 0.55), lineWidth: 0.6).offset(y: 0.5))
            .frame(height: 7)
    }

    @ViewBuilder
    private var cap: some View {
        if style == .hardware {
            realCap
        } else {
            // A key in this style, the cap's own size. The grip is its print:
            // one dark line, without the bevel's light edge.
            StyledSlab(shape: RoundedRectangle(cornerRadius: CarbonGeometry.styledRadius(3, for: style),
                                               style: .continuous),
                       fill: softSurfaces?.metal ?? theme.metal, hi: theme.metalHi, lo: theme.metalLo,
                       depth: FaderMetrics.styledCapDepth, outline: FaderMetrics.styledCapOutline)
                .frame(width: 11, height: 26)
                .overlay(Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.5, height: 20))
        }
    }

    private var realCap: some View {
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
            .depthShadow(color: Color.black.opacity(0.55), radius: 3, y: 3)
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
