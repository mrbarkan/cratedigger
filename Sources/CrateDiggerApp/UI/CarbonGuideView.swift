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
                        Text("Each is independent — set them separately in first-run setup or Preferences.")
                            .font(CarbonFont.sans(11)).foregroundStyle(theme.ink3)
                        concept("Local Library", "Where your albums & tracks live. Can be an external drive.")
                        concept("Library File location", "Where crate index (.cdlib) files are saved. Keep it on a local disk.")
                        concept("Default Output", "Where conversions go by default — not necessarily into your library.")
                    }

                    section("CORE CONCEPTS", accent: theme.orange) {
                        concept("Crates", "Top-level album categories — think Gmail's Priority / Updates / Promotions tabs. Each crate's index is a .cdlib file.")
                        concept("Prep Crate", "A temporary staging area. Newly scanned folders land here first — sort, clean, and convert before committing to a crate.")
                        concept("Library File", "A .cdlib crate index you can import, export, or back up.")
                    }

                    section("GETTING STARTED", accent: theme.cyan) {
                        bullet("Dig Crate (⌘O) — scan a folder of audio. Tracks land in the Prep Crate.")
                        bullet("Review & clean, then Add to Crate to file an album into a crate.")
                        bullet("Edit tags & artwork in the Inspector; right-click a track for more actions.")
                    }

                    section("CONVERTING", accent: theme.orange) {
                        bullet("Select an album or tracks → Convert Selected… (⇧⌘C).")
                        bullet("Pick a format on the Patch Bay; FFmpeg re-encodes to your Default Output (or a folder you choose).")
                    }

                    section("BACKING UP & SHARING", accent: theme.cyan) {
                        bullet("File → Library → Back Up Library… — one dated .zip of all your crate indexes.")
                        bullet("Import / Export Library File… — move individual .cdlib crates in or out.")
                        note("Your audio lives in the Local Library folder — back that up separately (it's just files).")
                    }

                    section("MINI PLAYER", accent: theme.orange) {
                        bullet("Window → Mini Player (or the footer button) — a floating player over your desktop.")
                        bullet("Cycle the art between CD / Vinyl / Album Cover; Expand returns to the full app.")
                    }

                    section("HANDY", accent: theme.cyan) {
                        bullet("Space — play / pause. Lock the POSITION dial to scroll-seek with the wheel or trackpad.")
                        bullet("Right-click a vinyl-rip file → Record Divider to split it into tracks.")
                        bullet("THEME (top-right) toggles light / dark.")
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
            BrandMark(size: 38)
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
