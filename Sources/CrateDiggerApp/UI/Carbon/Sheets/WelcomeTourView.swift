import SwiftUI

/// Visual welcome tour: a walkthrough of the CrateDigger model
/// (dig → organize → find → convert → play → make it yours), shown once on
/// first launch before the folder-setup sheet, and replayable from
/// Help ▸ Welcome Tour or the Interface preferences. Presented from
/// `model.showingWelcomeTour`.
///
/// The copy names real keys and real controls, so it goes stale when they
/// move. Anything renamed in the app has to be renamed here too.
struct WelcomeTourView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var page = 0

    private var pages: [TourPage] { TourPage.all }

    var body: some View {
        VStack(spacing: 0) {
            illustrationWell
            textBlock
            Spacer(minLength: 18)
            controls
        }
        .padding(28)
        .frame(width: 680, height: 540)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: page)
    }

    // MARK: - Illustration

    private var illustrationWell: some View {
        RecessedWell {
            ZStack {
                // Only the current page's illustration is in the tree; the
                // transition crossfades page changes.
                currentIllustration
                    .id(page)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
        }
    }

    @ViewBuilder private var currentIllustration: some View {
        switch pages[page].art {
        case .welcome: TourArtWelcome()
        case .dig: TourArtDig()
        case .organize: TourArtOrganize()
        case .find: TourArtFind()
        case .convert: TourArtConvert()
        case .play: TourArtPlay()
        case .yours: TourArtYours()
        }
    }

    // MARK: - Copy

    private var textBlock: some View {
        let current = pages[page]
        return VStack(alignment: .leading, spacing: 10) {
            Text(current.eyebrow)
                .font(CarbonFont.mono(9.5, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(current.accent(theme))
            Text(current.title)
                .font(CarbonFont.sans(22, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(current.body)
                .font(CarbonFont.sans(13))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3.5)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
        .id(page)
        .transition(.opacity)
    }

    // MARK: - Footer controls

    private var isLastPage: Bool { page == pages.count - 1 }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Skip Tour") { model.completeWelcomeTour() }
                .buttonStyle(.carbonHover)
                .font(CarbonFont.mono(10, weight: .semibold))
                .foregroundStyle(theme.ink3)

            Spacer()

            pageDots

            Spacer()

            Button("Back") { page = max(0, page - 1) }
                .disabled(page == 0)
            Button(isLastPage ? "Get Started" : "Continue") {
                if isLastPage {
                    model.completeWelcomeTour()
                } else {
                    page += 1
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == page ? theme.orange : theme.ink4.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .shadow(color: index == page ? theme.orange.opacity(0.6) : .clear, radius: 3)
                    .onTapGesture { page = index }
            }
        }
    }
}

// MARK: - Page model

private struct TourPage {
    enum Art { case welcome, dig, organize, find, convert, play, yours }

    let art: Art
    let eyebrow: String
    let title: String
    let body: String
    let accentKey: AccentKey

    enum AccentKey { case cyan, orange, sun, indigo }

    func accent(_ theme: CarbonTheme) -> Color {
        switch accentKey {
        case .cyan: return theme.cyan
        case .orange: return theme.orange
        case .sun: return theme.sun
        case .indigo: return theme.indigo
        }
    }

    static let all: [TourPage] = [
        TourPage(
            art: .welcome,
            eyebrow: "WELCOME",
            title: "Your record collection, on a workbench",
            body: "CrateDigger reads the folders your music already lives in, then hands you the tools to sort it, repair it, convert it and play it. The tour takes about a minute, and you can replay it any time from Help ▸ Welcome Tour.",
            accentKey: .cyan),
        TourPage(
            art: .dig,
            eyebrow: "STEP 1 · DIG",
            title: "Dig a crate, stage it first",
            body: "DIG CRATE (⌘O) scans any folder of audio. Everything lands in the Prep Crate first, a staging area where you look it over before it joins your library. Scanning only reads: nothing on disk moves unless you ask it to.",
            accentKey: .orange),
        TourPage(
            art: .organize,
            eyebrow: "STEP 2 · ORGANIZE",
            title: "File it into crates, fix what is broken",
            body: "Crates are your categories, listed in Sources and saved as small .cdcrate index files. Select albums and press ADD TO CRATE, then fix tags and artwork in the Inspector. FIX TAGS looks a release up for you, and DEEP SCAN identifies one from the audio itself when the tags are useless.",
            accentKey: .sun),
        TourPage(
            art: .find,
            eyebrow: "STEP 3 · FIND",
            title: "Search it, and browse it your way",
            body: "⌘F searches artist, album, title, path and format at once, and every crate in the sidebar shows how many matches it holds. The columns are yours too: set any of them to Genre, Year, Decade, Format or Rating, and each crate remembers its own arrangement.",
            accentKey: .cyan),
        TourPage(
            art: .convert,
            eyebrow: "STEP 4 · CONVERT",
            title: "Convert anything to anything",
            body: "Select tracks and press Convert (⇧⌘C). FFmpeg re-encodes to the format you pick and writes clean, collision-safe files into your Default Output folder, carrying tags and artwork across with them.",
            accentKey: .orange),
        TourPage(
            art: .play,
            eyebrow: "STEP 5 · SPIN",
            title: "Play it, and pick up where you left off",
            body: "Space plays and pauses anywhere. Quit mid-record and CrateDigger comes back on the same track, at the same second, with the same Up Next. There is a Mini Player, CD ripping, YouTube radio, and a Record Divider that cuts a continuous vinyl rip into tracks.",
            accentKey: .indigo),
        TourPage(
            art: .yours,
            eyebrow: "LAST · MAKE IT YOURS",
            title: "The console is yours",
            body: "Three themes ship with the app and the editor builds more: colours, geometry, fonts, even your own logo in the header. STATS (⌘5) keeps score of what you actually play, by month, by year or all time. A welcome record is waiting in your Personal Crate. Give it a spin.",
            accentKey: .sun),
    ]
}

// MARK: - Illustrations
//
// Small stylized mockups drawn with basic shapes so they follow the theme in
// light and dark. Each sits inside the 190pt-tall recessed well.

/// Brand mark over a faint three-pane app silhouette.
private struct TourArtWelcome: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                paneRect(width: 78)
                paneRect(width: 168)
                paneRect(width: 78)
            }
            .frame(height: 130)
            .opacity(0.5)

            AppIconView()
                .frame(width: 84, height: 84)
                .depthShadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.2), radius: 10, y: 5)
        }
    }

    private func paneRect(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.paper.opacity(theme.isDark ? 0.5 : 0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.hair, lineWidth: 1)
            )
            .frame(width: width)
    }
}

/// Folder → dashed conveyor → Prep Crate.
private struct TourArtDig: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.cyan)
                caption("MIXED FOLDER")
            }

            flowArrow

            VStack(spacing: 8) {
                crateBox
                caption("PREP CRATE")
            }
        }
    }

    private var flowArrow: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { _ in
                Circle().fill(theme.ink4).frame(width: 4, height: 4)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.orange)
        }
    }

    private var crateBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.orange.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.orange, lineWidth: 1.6)
                )
                .frame(width: 84, height: 60)
            // Record spines peeking out of the crate.
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.ink2.opacity(0.85))
                        .frame(width: 7, height: index % 2 == 0 ? 40 : 34)
                }
            }
            .offset(y: -4)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(8.5, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(theme.ink3)
    }
}

/// Sources sidebar with crates + an album card with tag chips.
private struct TourArtOrganize: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            // Mini sources pane
            VStack(alignment: .leading, spacing: 7) {
                sidebarRow("PREP CRATE", accent: theme.orange, filled: false)
                sidebarRow("PERSONAL CRATE", accent: theme.sun, filled: true)
                sidebarRow("DISCO 45s", accent: theme.sun, filled: false)
                sidebarRow("BREAKS", accent: theme.sun, filled: false)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.paper.opacity(theme.isDark ? 0.55 : 0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.hair, lineWidth: 1)
                    )
            )

            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.sun)

            // Album card
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(colors: [theme.indigo, theme.cyan],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 76, height: 76)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.4)
                            .frame(width: 30, height: 30)
                    )
                RoundedRectangle(cornerRadius: 2).fill(theme.ink2).frame(width: 66, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(theme.ink4).frame(width: 44, height: 5)
                HStack(spacing: 4) {
                    tagChip("FUNK")
                    tagChip("1974")
                }
            }
        }
    }

    private func sidebarRow(_ name: String, accent: Color, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 8))
                .foregroundStyle(accent)
            Text(name)
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1)
                .foregroundStyle(filled ? theme.ink : theme.ink3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(filled ? accent.opacity(0.18) : Color.clear)
        )
    }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(7, weight: .bold))
            .foregroundStyle(theme.cyan)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.cyan.opacity(0.14)))
    }
}

/// A search field over three column headers, one of which has been switched
/// away from the default — the point of the page.
private struct TourArtFind: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        VStack(spacing: 14) {
            searchField

            HStack(spacing: 8) {
                columnHeader("ARTIST", picked: false)
                columnHeader("GENRE", picked: true)
                columnHeader("YEAR", picked: true)
            }

            HStack(spacing: 14) {
                crateCount("BREAKS", count: "24", lit: true)
                crateCount("DISCO 45s", count: "6", lit: true)
                crateCount("JAZZ", count: "0", lit: false)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.cyan)
            Text("mil blue")
                .font(CarbonFont.mono(11, weight: .semibold))
                .foregroundStyle(theme.ink)
            // A caret, so the field reads as live rather than filled in.
            RoundedRectangle(cornerRadius: 0.5)
                .fill(theme.cyan)
                .frame(width: 1.5, height: 13)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.paper.opacity(theme.isDark ? 0.55 : 0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.cyan.opacity(0.7), lineWidth: 1.2)
                )
        )
    }

    private func columnHeader(_ name: String, picked: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(picked ? theme.cyan : theme.ink3)
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(picked ? theme.cyan : theme.ink4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 78)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(picked ? theme.cyan.opacity(0.14) : theme.paper.opacity(theme.isDark ? 0.45 : 0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(picked ? theme.cyan.opacity(0.55) : theme.hair, lineWidth: 1)
                )
        )
    }

    private func crateCount(_ name: String, count: String, lit: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 7))
                .foregroundStyle(lit ? theme.sun : theme.ink4)
            Text(name)
                .font(CarbonFont.mono(7.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(lit ? theme.ink2 : theme.ink4)
            Text(count)
                .font(CarbonFont.mono(7.5, weight: .bold))
                .foregroundStyle(lit ? theme.cyan : theme.ink4)
        }
        .opacity(lit ? 1 : 0.55)
    }
}

/// Three theme faceplates and a scoreboard: the two things this page is
/// about, side by side.
private struct TourArtYours: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    faceplate(body: theme.chassis, lamp: theme.orange, ink: theme.ink)
                    faceplate(body: theme.indigo.opacity(0.85), lamp: theme.sun, ink: .white)
                    faceplate(body: theme.ink, lamp: theme.cyan, ink: theme.cyan)
                }
                caption("THEMES")
            }

            VStack(spacing: 8) {
                scoreboard
                caption("STATS · ⌘5")
            }
        }
    }

    private func faceplate(body: Color, lamp: Color, ink: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(body)
            .overlay(
                VStack(alignment: .leading, spacing: 4) {
                    Circle()
                        .fill(lamp)
                        .frame(width: 6, height: 6)
                        .shadow(color: lamp.opacity(0.8), radius: 3)
                    RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.5)).frame(width: 26, height: 3)
                    RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.3)).frame(width: 18, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.hair, lineWidth: 1)
            )
            .frame(width: 46, height: 62)
    }

    /// The OLED is always a dark surface, in either appearance.
    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("MOST PLAYED")
                .font(CarbonFont.mono(7, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Color.white.opacity(0.55))
            Text("MOON SAFARI")
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.orange)
            HStack(spacing: 6) {
                Text("148 PLAYS")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text("THIS YEAR")
                    .font(CarbonFont.mono(7, weight: .bold))
                    .foregroundStyle(theme.cyan)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(theme.cyan.opacity(0.18)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 158, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.oledSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.oledStrokeInner, lineWidth: 1)
                )
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(8.5, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(theme.ink3)
    }
}

/// Format chips patched into an output format, Conversion-panel style.
private struct TourArtConvert: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .trailing, spacing: 10) {
                formatChip("FLAC", dim: false)
                formatChip("WAV", dim: true)
                formatChip("OGG", dim: true)
            }

            VStack(spacing: 4) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.orange)
                Text("CONVERSION")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
            }

            VStack(alignment: .leading, spacing: 8) {
                outputChip("MP3 · 320")
                Text("→ DEFAULT OUTPUT")
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    private func formatChip(_ name: String, dim: Bool) -> some View {
        Text(name)
            .font(CarbonFont.mono(10, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(dim ? theme.ink4 : theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.paper.opacity(dim ? 0.4 : 0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(dim ? theme.hair : theme.cyan, lineWidth: 1.2)
                    )
            )
    }

    private func outputChip(_ name: String) -> some View {
        Text(name)
            .font(CarbonFont.mono(11, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(theme.orange)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.orange.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.orange, lineWidth: 1.4)
                    )
            )
            .shadow(color: theme.orange.opacity(0.35), radius: 6)
    }
}

/// Spinning record + the app's real transport look (chrome keys around the
/// orange play dome — kept visually identical to `TransportCluster` /
/// `PlayDomeButton`, just non-interactive).
private struct TourArtPlay: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 30) {
            // Vinyl disc
            ZStack {
                Circle()
                    .fill(theme.isDark ? Color(hex: 0x0A0A09) : theme.ink)
                    .frame(width: 104, height: 104)
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 92 - CGFloat(index) * 18, height: 92 - CGFloat(index) * 18)
                }
                Circle()
                    .fill(theme.orange)
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(theme.isDark ? Color(hex: 0x0A0A09) : theme.ink)
                    .frame(width: 5, height: 5)
                // Position stripe so the rotation reads.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 3, height: 26)
                    .offset(y: -38)
            }
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 5).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    chromeKey("backward.end.fill")
                    playDome
                    chromeKey("forward.end.fill")
                }
                Text("SPACE · PLAY / PAUSE")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(theme.ink3)
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.cyan)
                    Text("RADIO · MINI PLAYER · DIVIDER")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(theme.ink3)
                }
            }
        }
    }

    /// Mirror of TransportCluster.transportButton, at 80% footer scale.
    private func chromeKey(_ symbol: String) -> some View {
        SiliconeCap(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
        }
        .frame(width: geometry.transportButtonSize * 0.8,
               height: geometry.transportButtonSize * 0.8)
    }

    /// Mirror of PlayDomeButton's dome, at 80% footer scale.
    private var playDome: some View {
        SiliconeCap(shape: Circle(), lit: true) {
            Image(systemName: "play.fill").font(.system(size: 21, weight: .black))
        }
        .frame(width: geometry.playButtonSize * 0.8,
               height: geometry.playButtonSize * 0.8)
    }
}
