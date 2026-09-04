import SwiftUI

/// In-app guide / FAQ (Help → CrateDigger Guide). A scrollable Carbon page that
/// explains the model: the three folders, Crates / Prep Crate / Library Files,
/// and the core workflows. Static content — no view model needed.
struct CarbonGuideView: View {
    /// Concrete light/dark resolved by the window controller (see CarbonAboutView).
    let mode: AppearanceMode

    var body: some View {
        GuideContent().carbonThemed(mode: mode)
    }
}

private struct GuideContent: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        ChassisLayer {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    section("THE THREE FOLDERS", accent: theme.cyan) {
                        Text("Each is independent. Set them in first-run setup or in Preferences.")
                            .font(CarbonFont.sans(11)).foregroundStyle(theme.ink3)
                        concept("Music Folder", "Where your albums and tracks live. Can be an external drive.")
                        concept("Crates Index", "Where crate index (.cdcrate) files are saved, not your music. Keep it on a local disk.")
                        concept("Default Output", "Where conversions go by default. It does not have to be inside your library.")
                    }

                    section("CORE CONCEPTS", accent: theme.orange) {
                        concept("Crates", "Your top-level categories, listed in Sources. A crate is a .cdcrate file listing which tracks belong to it; the tracks themselves are stored once and shared between crates, so filing a record in two places costs nothing.")
                        concept("Prep Crate", "A staging area. Newly scanned folders land here first, so you can review, repair and convert before committing anything to a crate.")
                        concept("All Records", "Everything you have scanned, whatever crate it sits in.")
                    }

                    section("GETTING STARTED", accent: theme.cyan) {
                        bullet("Dig Crate (⌘O) scans a folder of audio. Tracks land in the Prep Crate.")
                        bullet("Review what arrived, then Add to Crate to file an album where it belongs.")
                        bullet("Edit tags and artwork in the Inspector. Right-click a track for the rest.")
                        note("Scanning only reads. Nothing on disk moves unless you ask: Move Music Files… and Consolidate Music Files… live in Preferences.")
                    }

                    section("FINDING THINGS", accent: theme.sun) {
                        bullet("Find (⌘F) searches artist, album, title, file path and format at once. Every word has to match something, so \"mil blue\" finds Kind of Blue.")
                        bullet("While a search runs, each crate in Sources shows its match count, and clicking one keeps the query. CRATE / ALL widens the search to everything.")
                        bullet("Click a browser column's header to change what it shows: Artist, Album Artist, Album, Genre, Year, Decade, Format, Rating or Track. The layout key sets how many columns there are, and every crate remembers its own arrangement.")
                        bullet("Escape clears the search. The magnifier in the browser header puts the field away.")
                    }

                    section("FIXING TAGS & ARTWORK", accent: theme.orange) {
                        bullet("FIX TAGS matches a selected album against MusicBrainz and iTunes by name, and shows you every change before it writes anything.")
                        bullet("DEEP SCAN is for when the tags are blank or wrong: it fingerprints the audio and identifies the record from the sound, not the text.")
                        bullet("FIND ART searches the Cover Art Archive, Discogs, iTunes and Deezer, and shows what is already embedded in your files. Images stage first and are only written when you say so.")
                        bullet("The CLEANUP key in the Inspector relinks tracks whose files moved, finds duplicates, and flags albums whose covers are too small.")
                    }

                    section("CONVERTING", accent: theme.orange) {
                        bullet("Select an album or some tracks, then Convert Selected… (⇧⌘C).")
                        bullet("Pick a format in the Conversion panel. FFmpeg re-encodes into your Default Output, or a folder you choose, keeping tags and artwork.")
                        bullet("Filenames never collide: a name already taken gets (2), (3) and so on.")
                    }

                    section("PLAYING", accent: theme.indigo) {
                        bullet("Space plays and pauses anywhere. Lock the POSITION dial to scroll-seek with a wheel or trackpad.")
                        bullet("Quit mid-record and CrateDigger comes back on the same track, at the same second, with the same Up Next.")
                        bullet("Drag rows in the QUEUE tab to reorder what is coming. The EQ has three slots of your own and imports AutoEQ configs.")
                        bullet("Window ▸ Mini Player floats a small player over your desktop. Cycle its art between CD, vinyl and cover.")
                    }

                    section("BEYOND YOUR OWN FILES", accent: theme.cyan) {
                        bullet("Audio CDs mount as a source and rip straight into a crate.")
                        bullet("YouTube radio streams live sets and mixes, if yt-dlp is installed.")
                        bullet("A Subsonic or Navidrome server appears as a remote library.")
                        bullet("iPods and USB players you have saved appear under Devices, and Transfer to Device… (⇧⌘T) converts on the way if it has to.")
                    }

                    section("RECORD DIVIDER", accent: theme.sun) {
                        bullet("Right-click a continuous vinyl-side rip and choose Record Divider.")
                        bullet("It finds the gaps for you, and the sensitivity slider decides how eager it is. Drag the markers, name the tracks, and export one file per track.")
                    }

                    section("STATS", accent: theme.indigo) {
                        bullet("CrateDigger keeps a private record of what you play: counts, skips, when you last heard something, and when you added it.")
                        bullet("The STATS screen (⌘5) shows your most played record, artist and track, for this month, this year or all time.")
                    }

                    section("MAKING IT YOURS", accent: theme.orange) {
                        bullet("Carbon, Cobalt and Llama '97 ship with the app. The THEME key cycles them; Appearance ▸ Theme Editor… builds your own.")
                        bullet("A theme carries colours, geometry, fonts and its own logo for the header, in light and dark. Drop a .cdtheme folder in the Themes folder to install one.")
                    }

                    section("BACKING UP & SHARING", accent: theme.cyan) {
                        bullet("File ▸ Library ▸ Back Up Library… writes one dated .zip of every crate index.")
                        bullet("Import / Export Library File… moves individual crates in and out.")
                        note("Your audio lives in the Music Folder. Back that up separately: it is just files.")
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Top inset keeps the header clear of the window's traffic-light
                // controls at rest; the mask below handles scrolled content.
                .padding(.top, 40)
                .padding(.bottom, 14)
            }
            // Content scrolling up dissolves into the chassis instead of sliding
            // solid under the traffic lights.
            .mask(topFadeMask)
        }
        .frame(minWidth: 600, minHeight: 560)
    }

    /// Fully hides the band that sits under the traffic lights, then ramps to
    /// opaque so the rest of the page reads normally.
    private var topFadeMask: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 16)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
            Color.black
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("CrateDigger Guide")
                    .font(CarbonFont.sans(22, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("How the pieces fit together.")
                    .font(CarbonFont.sans(12))
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    private func section<Inner: View>(_ title: String, accent: Color,
                                      @ViewBuilder content: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(CarbonFont.mono(10.5, weight: .bold)).tracking(2)
                .foregroundStyle(accent)
            content()
        }
    }

    private func concept(_ term: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(CarbonFont.sans(13, weight: .bold)).foregroundStyle(theme.ink)
            Text(desc).font(CarbonFont.sans(12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(theme.ink4).frame(width: 4, height: 4).padding(.top, 6)
            Text(text).font(CarbonFont.sans(12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(9.5)).foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.cyan.opacity(0.08)))
    }
}
