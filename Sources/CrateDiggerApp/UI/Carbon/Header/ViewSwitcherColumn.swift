import AppKit
import CrateDiggerCore
import SwiftUI

/// Right-hand header column, the brand column's mirror: the theme's logo where
/// the left has "CrateDigger", then the DISPLAY screen tile (OLED mode) and
/// three settings buttons — VIEW / THEME / EQ — each showing a dot indicator
/// row for its current option. Same row grid as `BrandBlock`
/// (`HeaderKeyMetrics`), so the two columns' keys line up across the glass.
struct ViewSwitcherColumn: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: HeaderKeyMetrics.rowGap) {
            ThemeLogo()
                .frame(height: HeaderKeyMetrics.brandRowHeight)

            DisplayModeButton()

            SwitchButton(
                name: "VIEW",
                dotCount: 2,
                activeIndex: model.showArtworkGallery ? 1 : 0,
                tip: "VIEW — switch the browser between the track list and the artwork gallery."
            ) {
                ClickPlayer.shared.play(.key)
                model.showArtworkGallery.toggle()
            }

            SwitchButton(
                name: theme.word("THEME"),
                dotCount: 0,
                activeIndex: 0,
                dash: true,
                lit: model.showingThemePicker,
                tip: theme.word("THEME — appearance and installed skins, in the inspector.")
            ) {
                ClickPlayer.shared.play(.key)
                // Same gesture as CNVRT: the key swaps the inspector for its
                // panel, and pressing it again puts the inspector back.
                model.showingThemePicker.toggle()
            }

            SwitchButton(
                name: "EQ",
                dotCount: 1,
                activeIndex: model.eqEnabled ? 0 : -1,   // lit while the EQ shapes playback
                tip: "EQ: open the equalizer. The lamp is lit while it shapes playback."
            ) {
                ClickPlayer.shared.play(.key)
                model.showingEQEditor = true
            }
        }
        .padding(.top, HeaderKeyMetrics.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

}

/// A header settings button: left-aligned name + right-aligned dot indicators
/// (or, with `dash`, a dash LED that lights on each press — THEME's cycle has
/// no fixed option count, so the lamp acknowledges the click instead).
private struct SwitchButton: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    let name: String
    let dotCount: Int
    let activeIndex: Int
    var dash = false
    /// Holds the dash lamp on for as long as the key's panel is open, rather
    /// than blinking once per press — THEME is now a toggle, so the lamp
    /// reports state instead of acknowledging a click.
    var lit = false
    var tip: String? = nil
    let action: () -> Void

    @State private var dashLit = false

    // The column is a fixed 110pt (`CarbonLayout.viewSwitchWidth`), so the two
    // halves of the button get an explicit share each rather than competing for
    // it. Letting them negotiate produced both failure modes in turn: a lamp row
    // wide enough to push THEME's button past the column, then a budget small
    // enough that "VIEW" and "THEME" truncated to "V…" and "T…".
    //
    //   8 + 42 (label) + 4 (gap) + 44 (lamps) + 8 = 106, inside 110.
    private static let labelWidth: CGFloat = 42
    private static let lampBudget: CGFloat = 44
    private static let horizontalPadding: CGFloat = 8

    /// Lamps shrink to stay inside the budget rather than widening the button.
    private var dotSize: CGFloat {
        guard dotCount > 0 else { return 5 }
        let spacingTotal = dotSpacing * CGFloat(max(0, dotCount - 1))
        return min(5, max(3, (Self.lampBudget - spacingTotal) / CGFloat(dotCount)))
    }

    private var dotSpacing: CGFloat { dotCount > 4 ? 2.5 : 3 }

    /// The lamps sit against the trailing edge of their share, so all three
    /// buttons' indicators line up regardless of what they contain.

    var body: some View {
        Button(action: fire) {
            HStack(spacing: 4) {
                // Same face as the library keys opposite (`LibButton`): the two
                // columns are one set of parts.
                Text(name)
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    // Scales down a hair rather than truncating to "T…" if a
                    // label ever outgrows its share.
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                if dotCount > 0 {
                    HStack(spacing: dotSpacing) {
                        ForEach(0..<dotCount, id: \.self) { i in
                            Circle()
                                .fill(i == activeIndex ? theme.keyLamp : theme.ink4.opacity(0.4))
                                .frame(width: dotSize, height: dotSize)
                                .shadow(color: i == activeIndex ? theme.keyLamp.opacity(0.7) : .clear, radius: 2.5)
                        }
                    }
                    .frame(width: Self.lampBudget, alignment: .trailing)
                }
                if dash {
                    let on = lit || dashLit
                    Capsule(style: .continuous)
                        .fill(on ? theme.keyLamp : theme.ink4.opacity(0.4))
                        .frame(width: 14, height: 4)
                        .shadow(color: on ? theme.keyLamp.opacity(0.7) : .clear, radius: 3)
                        // Same budget as the lamp rows, so THEME's trailing edge
                        // lines up with VIEW's and EQ's.
                        .frame(width: Self.lampBudget, alignment: .trailing)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChromeChassis(theme: theme, cornerRadius: geometry.keyCornerRadius))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(tip ?? "\(name): tap to change")
    }

    private func fire() {
        if dash {
            dashLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.4)) { dashLit = false }
            }
        }
        action()
    }
}
