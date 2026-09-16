import CrateDiggerCore
import SwiftUI

/// Release notes as a sheet: what changed, plus a standing summary of theming
/// with enough of how it works that nobody has to go looking for it.
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

            // Theming is the one item here people act on immediately, so it
            // gets a door rather than directions to the menu item.
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

    /// Edit this list each release. Shown in order, so the biggest thing
    /// goes first and theming stays last, beside the button that opens it.
    static let current: [WhatsNewItem] = [
        WhatsNewItem(
            symbol: "externaldrive.badge.xmark",
            title: "Your library, even with the drive unplugged",
            body: """
            If your library index lives on an external drive, CrateDigger now \
            keeps a copy of it on this Mac. Launch without the drive and your \
            crates, albums, covers, play counts and ratings are all still there, \
            dimmed, with a note naming the drive that is out. Changes wait until \
            it is back, and plugging it in brings the live library back by \
            itself. Before, the app said No library loaded and started an empty \
            one in its place.
            """
        ),
        WhatsNewItem(
            symbol: "waveform",
            title: "A quieter bottom shelf",
            body: """
            The EQ display and the VU meter have left the bottom of the window, \
            which now holds the position dial, the transport and the volume \
            knob. A small spectrum meter sits beside the clock on the NOW screen \
            instead, moving while a record or a stream plays and settling flat \
            when you pause.
            """
        ),
        WhatsNewItem(
            symbol: "slider.vertical.3",
            title: "The EQ key opens the equalizer",
            body: """
            Press EQ in the header for the equalizer's faders, presets and \
            AutoEQ import. The key no longer steps through presets: pick one on \
            the preset keys. Its lamp is lit while the equalizer is on.
            """
        ),
        WhatsNewItem(
            symbol: "paintpalette",
            title: "Everything about theming, in one place",
            body: """
            Press THEME in the header for the theme browser, then EDITOR to \
            start changing one. Every colour, corner radius and typeface is a \
            control, and the app repaints as you work, so the preview is the \
            application behind the panel rather than a picture of it. One theme \
            carries both a light and a dark version and follows your system \
            setting. Any font on your Mac can letter the interface, with the \
            family's real weights mapped rather than smeared. A theme can carry \
            its own logo for the header, framed in the editor. Seven one-click \
            presets restyle the glass alone, from green LCD to e-paper, and each \
            lamp on the display takes its own colour. UNDO steps back through \
            your last ten changes. A finished theme is a small .cdtheme folder \
            you can zip and send to anyone.
            """
        ),
    ]
}
