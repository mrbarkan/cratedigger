import CrateDiggerCore
import SwiftUI

// MARK: - Switch size

enum PatchBaySwitchSize {
    /// Short labels (4 chars: ALAC, FLAC, OPUS, 96/128/.../320, 32K, 44.1K).
    case small
    /// Full-text rocker labels (SOURCE, FLAT, TEMPLATE, ALBUM, etc.).
    case medium

    func minWidth(in geometry: CarbonGeometry) -> CGFloat {
        switch self {
        case .small:  return geometry.patchBayKeyMinWidthSmall
        case .medium: return geometry.patchBayKeyMinWidthMedium
        }
    }
}

// MARK: - Themed switch button (the "key" inside a bank)

/// Standardized fixed-width switch used inside `PatchBayBank`. Width is
/// intrinsic (not flexible) — required for the `ViewThatFits` cycle-button
/// fallback to detect overflow.
///
/// In a style other than Real Hardware it is the style's key (lit with the
/// accent when on) and answers a press as that style does; the frame and the
/// hit area are the same in every style.
struct PatchBaySwitch: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    let label: String
    var sub: String? = nil
    var on: Bool
    var disabled: Bool = false
    var size: PatchBaySwitchSize = .small
    let action: () -> Void

    @State private var hovering = false

    /// The key's own radius, which is also where it takes clicks.
    private static let cornerRadius: CGFloat = 4

    var body: some View {
        let button = Button(action: action) {
            face
                .frame(minWidth: size.minWidth(in: geometry), maxWidth: size.minWidth(in: geometry))
                .frame(height: geometry.patchBayKeyHeight)
                .opacity(disabled ? 0.45 : 1)
        }
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(sub.map { "\(label) (\($0))" } ?? label))
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : [.isButton])

        if style == .hardware {
            button.buttonStyle(.carbonHover)
        } else {
            button.buttonStyle(StyledKeyButtonStyle(
                depth: StyledKeyMetrics.depth,
                hitShape: AnyShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))))
        }
    }

    /// No corner lamp and no glow: the lit fill already says which one is
    /// selected, and saying it three times was most of the funk.
    @ViewBuilder
    private var face: some View {
        if style == .hardware {
            content
                .background(background)
                .overlay(border)
        } else {
            content
                .background(styledBackground)
        }
    }

    /// The key in this style: the metal, or the accent while it is on.
    private var styledBackground: some View {
        StyledSlab(shape: RoundedRectangle(cornerRadius: CarbonGeometry.styledRadius(Self.cornerRadius, for: style),
                                           style: .continuous),
                   fill: on ? theme.orange : (softSurfaces?.metal ?? theme.metal),
                   hi: on ? theme.orangeHi : theme.metalHi,
                   lo: on ? theme.orangeLo : theme.metalLo,
                   depth: StyledKeyMetrics.depth, outline: StyledKeyMetrics.outline)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(on ? theme.accentInk : theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let sub {
                Text(sub)
                    .font(CarbonFont.mono(7.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(on ? theme.accentInk.opacity(0.7) : theme.ink3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape.fill(on ? theme.orange : theme.metal)
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if on {
            shape.stroke(theme.orange.opacity(0.45), lineWidth: 1)
        } else {
            shape.stroke(
                Color.white.opacity(theme.isDark ? (hovering ? 0.18 : 0.10) : (hovering ? 0.40 : 0.25)),
                lineWidth: 1
            )
        }
    }
}

// MARK: - Recess for switch banks

/// Glass tray behind fixed-width switch banks. In a style other than Real
/// Hardware it is the style's well, cut into the panel.
struct PatchBayRecess: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if style == .hardware {
            realTray
        } else {
            StyledSlab(shape: RoundedRectangle(cornerRadius: CarbonGeometry.styledRadius(6, for: style),
                                               style: .continuous),
                       fill: theme.wellDeep, lo: theme.metalDeep,
                       depth: StyledKeyMetrics.depth, sunken: true, outline: StyledKeyMetrics.outline)
        }
    }

    private var realTray: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack {
            shape
                .fill(theme.wellDeep) // opaque, not Material — see ChassisLayer
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.wellDeep.opacity(theme.isDark ? 0.62 : 0.54),
                                theme.metalDeep.opacity(theme.isDark ? 0.34 : 0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.10 : 0.28), lineWidth: 0.7)
                )
        }
        .compositingGroup()
        .depthShadow(color: Color.black.opacity(theme.isDark ? 0.44 : 0.16), radius: 3, y: 1)
    }
}

// MARK: - Cycle button (single-button fallback when a row can't fit)

/// Cycle button used as the narrow-fallback inside `PatchBayBank`. Tap = next
/// (wraps). Mirrors the header glass chrome so the patch bay stays coherent.
struct PatchBayCycleButton<Item: Hashable>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @Environment(\.interfaceStyle) private var style

    let label: String
    let options: [Item]
    @Binding var selection: Item
    /// Optional fallback used when `selection` isn't in `options` (e.g.
    /// stale persisted state). The button still renders a current label.
    let displayText: (Item) -> String

    /// The plate's own radius, which is also where it takes clicks.
    private static var cornerRadius: CGFloat { 5 }

    var body: some View {
        if style == .hardware {
            button.buttonStyle(.carbonHover)
        } else {
            button.buttonStyle(StyledKeyButtonStyle(
                depth: StyledKeyMetrics.depth,
                hitShape: AnyShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))))
        }
    }

    private var button: some View {
        Button(action: advance) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(currentText)
                        .font(CarbonFont.mono(11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    // Says "there is another one" without a second control.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(theme.orange.opacity(0.55))
                }
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)

                positionRail
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.patchBayCycleButtonHeight)
            .background(displayFace)
        }
        .accessibilityLabel(Text("\(label): \(currentText)"))
        .accessibilityHint(Text("Tap to advance"))
        .accessibilityValue(Text(currentText))
    }

    /// A hardware display reads black whatever the room light, so the screen
    /// stays dark in both themes and the orange readout stays legible.
    ///
    /// The plate is a key, so in a style other than Real Hardware it is the
    /// style's slab in the same dark; the readout and its scale on it are not
    /// the style's and stay as they are.
    @ViewBuilder
    private var displayFace: some View {
        if style == .hardware {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            shape
                .fill(LinearGradient(colors: [Self.faceTop, Self.faceBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                .depthShadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
        } else {
            StyledSlab(shape: RoundedRectangle(cornerRadius: CarbonGeometry.styledRadius(Self.cornerRadius, for: style),
                                               style: .continuous),
                       fill: Self.faceTop, lo: Self.faceBottom,
                       depth: StyledKeyMetrics.depth, outline: StyledKeyMetrics.outline)
        }
    }

    private static var faceTop: Color { Color(hex: 0x1A1F25) }
    private static var faceBottom: Color { Color(hex: 0x0B0E12) }

    /// Where you are in the cycle, as a hairline scale along the bottom edge
    /// rather than a row of lamps — same information, none of the fairground.
    private var positionRail: some View {
        HStack(spacing: 1.5) {
            ForEach(options, id: \.self) { item in
                Rectangle()
                    .fill(item == selection ? theme.orange : Color.white.opacity(0.10))
                    .frame(height: 1.5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 6)
    }

    private func advance() {
        guard !options.isEmpty else { return }
        let idx = options.firstIndex(of: selection) ?? -1
        let next = options[(idx + 1) % options.count]
        selection = next
    }

    private var currentText: String {
        if options.contains(selection) {
            return displayText(selection)
        }
        return options.first.map(displayText) ?? "—"
    }

}

// MARK: - Bank: full-row at intrinsic widths, falls through to cycle

/// Auto-selecting container. Shows full row of switches when there's room;
/// falls through to a single cycle button at narrower widths.
///
/// The "wide" candidate uses an `HStack` of fixed-width `PatchBaySwitch`
/// children. **It must NOT be a flexible LazyVGrid** — `ViewThatFits` would
/// always pick the flexible variant and the cycle-button fallback would
/// never fire.
struct PatchBayBank<Item: Hashable>: View {
    let label: String
    let options: [Item]
    @Binding var selection: Item
    var size: PatchBaySwitchSize = .small
    /// Optional disabled predicate (e.g. bitrate is disabled in lossless).
    var isDisabled: (Item) -> Bool = { _ in false }
    let displayText: (Item) -> String
    var subText: (Item) -> String? = { _ in nil }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Wide: fixed-width switches inside a recess
            HStack(spacing: 3) {
                ForEach(options, id: \.self) { item in
                    PatchBaySwitch(
                        label: displayText(item),
                        sub: subText(item),
                        on: item == selection,
                        disabled: isDisabled(item),
                        size: size,
                        action: { selection = item }
                    )
                }
            }
            .padding(3)
            .background(PatchBayRecess())

            // Narrow fallback: single cycle button
            PatchBayCycleButton(
                label: label,
                options: options,
                selection: $selection,
                displayText: displayText
            )
        }
    }
}
