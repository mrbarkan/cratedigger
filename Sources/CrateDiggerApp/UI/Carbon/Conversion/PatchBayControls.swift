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
struct PatchBaySwitch: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    let label: String
    var sub: String? = nil
    var on: Bool
    var disabled: Bool = false
    var size: PatchBaySwitchSize = .small
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // No corner lamp and no glow: the lit fill already says which one
            // is selected, and saying it three times was most of the funk.
            content
                .background(background)
                .overlay(border)
                .frame(minWidth: size.minWidth(in: geometry), maxWidth: size.minWidth(in: geometry))
                .frame(height: geometry.patchBayKeyHeight)
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.carbonHover)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(sub.map { "\(label) (\($0))" } ?? label))
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(on ? theme.selectionInk : theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let sub {
                Text(sub)
                    .font(CarbonFont.mono(7.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(on ? theme.selectionInk.opacity(0.7) : theme.ink3)
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

// MARK: - LED dot (theme-aware off-state)

struct LedDot: View {
    @Environment(\.carbon) private var theme
    let on: Bool

    var body: some View {
        Circle()
            .fill(on ? theme.selectionInk : ledOff)
            .frame(width: 4, height: 4)
            .overlay(
                Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: on ? Color.white.opacity(0.4) : .clear, radius: on ? 2 : 0)
    }

    private var ledOff: Color {
        // Light mode uses a dim graphite dot; dark mode keeps the near-black
        // inactive slot used by the OLED-adjacent controls.
        theme.isDark ? Color.black.opacity(0.6) : theme.ink3.opacity(0.4)
    }
}

// MARK: - Recess for switch banks

/// Glass tray behind fixed-width switch banks.
struct PatchBayRecess: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
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

    let label: String
    let options: [Item]
    @Binding var selection: Item
    /// Optional fallback used when `selection` isn't in `options` (e.g.
    /// stale persisted state). The button still renders a current label.
    let displayText: (Item) -> String

    var body: some View {
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
        .buttonStyle(.carbonHover)
        .accessibilityLabel(Text("\(label): \(currentText)"))
        .accessibilityHint(Text("Tap to advance"))
        .accessibilityValue(Text(currentText))
    }

    /// A hardware display reads black whatever the room light, so the screen
    /// stays dark in both themes and the orange readout stays legible.
    private var displayFace: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(hex: 0x1A1F25), Color(hex: 0x0B0E12)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            .depthShadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
    }

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

// MARK: - Themed paddle toggle

/// Paddle (capsule) toggle. Off-state uses theme metal/well tokens so it
/// reads as a slot rather than a punched hole on linen.
struct PatchBayPaddle: View {
    @Environment(\.carbon) private var theme
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isOn
                                ? [theme.orangeLo, theme.orange]
                                : [theme.metalDeep, theme.wellDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule().stroke(Color.black.opacity(theme.isDark ? 0.6 : 0.3), lineWidth: 0.5)
                    )
                    .shadow(color: isOn ? theme.orange.opacity(0.3) : .clear, radius: 4)

                Circle()
                    .fill(
                        isOn
                            ? LinearGradient(colors: [theme.orangeHi, theme.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [theme.metalHi, theme.metal, theme.metalLo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().stroke(Color.white.opacity(theme.isDark ? 0.2 : 0.5), lineWidth: 0.5)
                    )
                    .padding(2)
                    .depthShadow(color: Color.black.opacity(0.6), radius: 1, y: 1)
            }
            .frame(width: 30, height: 16)
        }
        .buttonStyle(.carbonHover)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
    }
}
