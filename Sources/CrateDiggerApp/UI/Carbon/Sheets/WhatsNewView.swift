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

    /// Edit this list each release. Shown in order.
    static let current: [WhatsNewItem] = [
        WhatsNewItem(
            symbol: "photo.on.rectangle.angled",
            title: "Deep scans from Discogs",
            body: """
            Artwork search now reaches Discogs, where the scans of physical \
            pressings live: gatefolds, inner sleeves, obi strips, label \
            close-ups, the back of the sleeve with the runout etched into it. \
            CrateDigger finds the release three ways in turn, by the link \
            MusicBrainz already holds, then by barcode, then by artist and \
            title. No account needed.
            """
        ),
        WhatsNewItem(
            symbol: "arrow.down.circle",
            title: "It updates itself",
            body: """
            Check for Updates now downloads the new version, verifies we signed \
            it, installs it and relaunches. No more fetching a disk image and \
            dragging the app across by hand. It also looks once a day without \
            being asked, and a stable install is never offered a release \
            candidate.
            """
        ),
        WhatsNewItem(
            symbol: "waveform",
            title: "The meters follow radio",
            body: """
            The VU needles used to sit flat through every broadcast, because \
            they were reading the library player that radio had just paused. \
            They now measure the app's own output, so they move for anything \
            you are listening to, live streams included. Needs macOS 14.4 or \
            later.
            """
        ),
        WhatsNewItem(
            symbol: "scope",
            title: "Go to Current Song",
            body: """
            Dig three crates deep and lose your place, then press it to land \
            back on the record you are hearing. It crosses crates: if the queue \
            came from somewhere other than the crate on screen, it switches \
            back to that one and reveals the track there.
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
            family's real weights mapped rather than smeared. Seven one-click \
            presets restyle the glass alone, from green LCD to e-paper, and \
            each of the six lamps on the display takes its own colour. UNDO \
            steps back through your last ten changes. A finished theme is a \
            small .cdtheme folder you can zip and send to anyone.
            """
        ),
    ]
}
