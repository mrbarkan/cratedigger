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
            symbol: "magnifyingglass",
            title: "Search your library",
            body: """
            A field across the top of the browser, results as you type, over \
            artist, album, title, file path and format. Every word has to match \
            something, so "mil blue" finds Kind of Blue and "flac live" finds \
            live FLACs. Command-F puts the cursor in it. While a search runs \
            every crate in the sidebar shows its match count, so you can see \
            where the results actually live.
            """
        ),
        WhatsNewItem(
            symbol: "rectangle.split.3x1",
            title: "Any category in any column",
            body: """
            The browser's columns are no longer welded to Artist, Album and \
            Track. Click a column's header and pick Album Artist, Genre, Year, \
            Decade, Format or Rating instead, and the layout key sets how many \
            columns there are. A view can end on a decade rather than a track \
            list, and every crate, playlist and device remembers its own \
            arrangement.
            """
        ),
        WhatsNewItem(
            symbol: "arrow.uturn.backward.circle",
            title: "Pick up where you left off",
            body: """
            Quit in the middle of a record and CrateDigger comes back paused on \
            the same track, at the same second, with the same Up Next, and the \
            crate it was playing from still marked in the sidebar. Press play to \
            carry on. Streams, CDs and remote libraries start fresh, as they \
            always have.
            """
        ),
        WhatsNewItem(
            symbol: "chart.bar.xaxis",
            title: "It keeps score",
            body: """
            CrateDigger remembers what you actually play: counts, skips, when \
            you last heard something and when you added it. The STATS screen \
            (Command-5) turns that into your most played record, artist and \
            track, with hours listened, for this month, this year or all time.
            """
        ),
        WhatsNewItem(
            symbol: "waveform",
            title: "Fix tags by listening to the record",
            body: """
            When a file's tags are blank or wrong, searching by text has nothing \
            to search with. DEEP SCAN fingerprints the audio instead, identifies \
            each recording from the sound, and lets the album's files vote on \
            which release they all belong to. It never reads the tags it is \
            there to replace.
            """
        ),
        WhatsNewItem(
            symbol: "photo.on.rectangle.angled",
            title: "Artwork worth framing",
            body: """
            FIND ART searches the Cover Art Archive, Discogs, iTunes and Deezer \
            in one window, and shows what is already embedded in your files \
            beside them. Discogs is where the scans of physical pressings live: \
            gatefolds, inner sleeves, obi strips, the back of the sleeve with the \
            runout etched into it. Nothing is written to your files until you \
            say so.
            """
        ),
        WhatsNewItem(
            symbol: "sparkles",
            title: "A new face",
            body: """
            The app icon is a record on an orange plate, and there is a mark to \
            go with it: a record half out of the crate the app is named for. The \
            name is set in the display face the OLED already speaks, so the \
            header and the screen share one voice.
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
