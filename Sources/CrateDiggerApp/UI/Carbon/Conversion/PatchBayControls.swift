import CrateDiggerCore
import SwiftUI

// MARK: - Switch size

enum PatchBaySwitchSize {
    /// Short labels (4 chars: ALAC, FLAC, OPUS, 96/128/.../320, 32K, 44.1K).
    case small
    /// Full-text rocker labels (SOURCE, FLAT, TEMPLATE, ALBUM, etc.).
    case medium

    var minWidth: CGFloat {
        switch self {
        case .small:  return CarbonLayout.patchBayKeyMinWidthSmall
        case .medium: return CarbonLayout.patchBayKeyMinWidthMedium
        }
    }
}

// MARK: - Themed switch button (the "key" inside a bank)

/// Standardized fixed-width switch used inside `PatchBayBank`. Width is
/// intrinsic (not flexible) — required for the `ViewThatFits` cycle-button
/// fallback to detect overflow.
struct PatchBaySwitch: View {
    @Environment(\.carbon) private var theme
    let label: String
    var sub: String? = nil
    var on: Bool
    var disabled: Bool = false
    var size: PatchBaySwitchSize = .small
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                content
                    .background(background)
                    .overlay(border)

                LedDot(on: on)
                    .padding(.top, 4)
                    .padding(.trailing, 5)
            }
            .frame(minWidth: size.minWidth, maxWidth: size.minWidth)
            .frame(height: CarbonLayout.patchBayKeyHeight)
            .opacity(disabled ? 0.45 : 1)
            .shadow(color: on ? theme.orange.opacity(0.30) : .clear, radius: 6, y: 0)
        }
        .buttonStyle(.plain)
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
                .minimumScaleFactor(0.85)
            if let sub {
                Text(sub)
                    .font(CarbonFont.mono(7.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(on ? theme.selectionInk.opacity(0.7) : theme.ink3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if on {
            shape.fill(
                LinearGradient(
                    colors: [theme.orange, theme.orangeLo],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            shape.fill(
                LinearGradient(
                    colors: [theme.metalHi, theme.metal, theme.metalLo],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
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
        // Linen: dim brown so the dot reads as recessed metal, not a
        // punched-through hole. Carbon: near-black slot.
        theme.isDark ? Color.black.opacity(0.6) : theme.ink3.opacity(0.4)
    }
}

// MARK: - Recess for switch banks

/// Theme-aware recess. Carbon: dark gradient + inverted shadow (a darker
/// edge over a darker chassis reads as depth). Linen: medium-metal gradient
/// + standard drop shadow on the bottom edge with a top highlight inset (an
/// inverted shadow on a light surface reads as a glow halo, so we ship a
/// different visual treatment per theme rather than just swapping colors).
struct PatchBayRecess: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        if theme.isDark {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x0E0E0C),
                                Color(hex: 0x1A1A18),
                                Color(hex: 0x0A0A08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.black.opacity(0.9), lineWidth: 1)
                    .blur(radius: 0.5)
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.6), radius: 1, y: -1)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.metalDeep, theme.metalLo, theme.metalDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // Top inset highlight — a thin bright line at the top inner
                // edge sells the recess on a light chassis.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    .mask(
                        LinearGradient(
                            colors: [Color.black, Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.20), radius: 1, y: 1)
        }
    }
}

// MARK: - Cycle button (single-button fallback when a row can't fit)

/// Skeuomorphic cycle button used as the narrow-fallback inside
/// `PatchBayBank`. Tap = next (wraps). Mirrors the chrome treatment of the
/// header `DisplayModeButton` so the look is coherent across the chassis.
struct PatchBayCycleButton<Item: Hashable>: View {
    @Environment(\.carbon) private var theme

    let label: String
    let options: [Item]
    @Binding var selection: Item
    /// Optional fallback used when `selection` isn't in `options` (e.g.
    /// stale persisted state). The button still renders a current label.
    let displayText: (Item) -> String

    var body: some View {
        Button(action: advance) {
            VStack(spacing: 4) {
                screen
                ledStrip
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .frame(height: CarbonLayout.patchBayCycleButtonHeight)
            .background(ChromeChassis(theme: theme, cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(label): \(currentText)"))
        .accessibilityHint(Text("Tap to advance"))
        .accessibilityValue(Text(currentText))
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

    @ViewBuilder
    private var screen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.wellDeep, theme.metalDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 1, y: 1)
            Text(currentText)
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.orange)
                .shadow(color: theme.orange.opacity(0.7), radius: 3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var ledStrip: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { item in
                Circle()
                    .fill(item == selection ? theme.orange : Color.black.opacity(0.35))
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(
                        color: item == selection ? theme.orange.opacity(0.7) : .clear,
                        radius: 2
                    )
            }
        }
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
                    .shadow(color: Color.black.opacity(0.6), radius: 1, y: 1)
            }
            .frame(width: 30, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
    }
}
