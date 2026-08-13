import CrateDiggerCore
import SwiftUI

/// Release notes as a sheet: what changed, and — for the theme editor — enough
/// of how it works that nobody has to go looking for it.
///
/// Deliberately a list rather than a paged walkthrough like `WelcomeTourView`.
/// The tour teaches a model you don't have yet, so it earns its illustrations
/// and its pacing; this is read once by someone who already knows the app and
/// wants to know what moved.
struct WhatsNewView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(WhatsNewItem.current) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }

            controls
        }
        .frame(width: 560, height: 520)
        .background(theme.chassis)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT'S NEW")
                .font(CarbonFont.mono(9.5, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(theme.orange)
            Text("CrateDigger \(AppVersion.marketing)")
                .font(CarbonFont.sans(24, weight: .bold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private func row(_ item: WhatsNewItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.orange.opacity(0.14))
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.orange)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(CarbonFont.sans(14, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text(item.body)
                    .font(CarbonFont.sans(12))
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2.5)
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            KeyButton(action: { model.showingWhatsNew = false }) { Text("CLOSE") }
                .frame(width: 96, height: geometry.keyHeight)

            // The whole point of the release: put people one click from it
            // rather than describing where the menu item lives.
            KeyButton(style: .glowingFilled, action: {
                model.showingWhatsNew = false
                model.showingThemePicker = true
            }) {
                Text("OPEN THEMES")
            }
            .frame(width: 140, height: geometry.keyHeight)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .top
        )
    }
}

/// One line of release notes. Kept beside the view because it *is* the copy —
/// there's nothing to reuse it for, and splitting it out would only mean two
/// files to edit per release.
struct WhatsNewItem: Identifiable {
    let symbol: String
    let title: String
    let body: String
    var id: String { title }

    /// Edit this list each release. Shown in order.
    static let current: [WhatsNewItem] = [
        WhatsNewItem(
            symbol: "paintpalette",
            title: "Theme Editor",
            body: """
            Press THEME in the header to open the theme browser in the \
            inspector, then EDITOR to start changing one. Every colour, corner \
            radius and typeface is a control, and the app repaints as you go — \
            what you see behind the panel is the theme.
            """
        ),
        WhatsNewItem(
            symbol: "circle.lefthalf.filled",
            title: "One theme, light and dark",
            body: """
            Set a theme to BOTH and it carries a light and a dark version and \
            follows your system setting, instead of shipping as two separate \
            themes. COPY TO LIGHT/DARK starts one version from the other so \
            you're tweaking rather than rebuilding.
            """
        ),
        WhatsNewItem(
            symbol: "textformat",
            title: "Fonts, with real weights",
            body: """
            Pick any font installed on your Mac for the interface, the readouts \
            or the display, and choose which style is the base. The family's \
            actual weights are mapped, so bold headings use a drawn bold rather \
            than a smeared regular. Fonts can also be bundled inside a theme so \
            it travels with them.
            """
        ),
        WhatsNewItem(
            symbol: "square.and.arrow.up",
            title: "Themes are files you can share",
            body: """
            A theme is a small JSON file in a .cdtheme folder. Save yours, \
            REVEAL it in Finder, zip it, send it on — and drop someone else's \
            into the same folder to install it. Appearance in the menu bar \
            lists everything installed.
            """
        ),
        WhatsNewItem(
            symbol: "swatchpalette",
            title: "Cobalt",
            body: """
            A new built-in theme, and a worked example of the format: shared \
            accents, separate light and dark layers, custom corner radii and a \
            mapped font family. Duplicate it in the editor to start your own.
            """
        ),
    ]
}
