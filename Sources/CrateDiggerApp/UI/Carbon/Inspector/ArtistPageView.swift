import AppKit
import CrateDiggerCore
import SwiftUI

/// The inspector's INFO tab while the browser is on an artist (spec §1, §2):
/// portrait, name, one line of facts, the Wikipedia bio with its credit,
/// members, genres, what the library holds, how it is listened to, links.
/// When the lookup could not tell same-named acts apart, "Is this them?"
/// takes the place of the facts and the bio.
///
/// Reads only what the view model has already published (profiles,
/// summaries, the top tracks); the one thing it loads itself is the
/// portrait's thumbnail, off the main actor.
struct ArtistPageView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.openURL) private var openURL
    let name: String

    @State private var bioExpanded = false

    /// A lead paragraph past this many characters is clamped, with "More".
    private static let bioClampLength = 300
    /// Wider than the album page's 78, for LAST PLAYED.
    private static let keyWidth: CGFloat = 94

    private var profile: ArtistProfile? { model.artistProfile(named: name) }
    private var summary: ArtistLibrarySummary? { model.artistSummary(named: name) }
    private var facts: ArtistFacts { profile?.facts ?? ArtistFacts() }
    private var isLookedUp: Bool { ArtistLookupScheduler.isLookedUp(name) }
    private var isLookingUp: Bool { model.isLookingUpArtist(name) }

    private var uncertainCandidates: [ArtistIdentityCandidate]? {
        guard case .uncertain(let candidates)? = profile?.identity, !candidates.isEmpty else { return nil }
        return candidates
    }

    private var isConfirmed: Bool {
        if case .confirmed? = profile?.identity { return true }
        return false
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ArtistPortrait(name: name, photo: profile?.defaultPhotoRef) { portraitMenu }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                caption
                    .id(Self.captionID)
                if let candidates = uncertainCandidates {
                    identityQuestion(candidates)
                } else {
                    bio
                    members
                    genres
                }
                librarySection
                listeningSection
                linksRow
                Color.clear.frame(height: 1).id(Self.endID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if DEBUG
        // `CRATEDIGGER_ARTIST_PAGE_SCROLL=end` (or `name`): the page
        // scrolled to its end (or to the name under the portrait), so a
        // capture can show what sits below the portrait.
        .task(id: name) {
            let scroll = ProcessInfo.processInfo.environment["CRATEDIGGER_ARTIST_PAGE_SCROLL"]
            guard scroll == "end" || scroll == "name" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if scroll == "end" {
                proxy.scrollTo(Self.endID, anchor: .bottom)
            } else {
                proxy.scrollTo(Self.captionID, anchor: .top)
            }
        }
        #endif
        }
        .onChange(of: name) { _ in bioExpanded = false }
    }

    private static let endID = "artist-page-end", captionID = "artist-page-caption"

    // MARK: - Portrait menu

    @ViewBuilder
    private var portraitMenu: some View {
        // Task 8: the Edit sheet and the photo picker.
        Button("Choose Default…") {}
            .disabled(true)
        Button("Add Photos…") {}
            .disabled(true)
        Divider()
        Button("Look Up Again") { model.lookUpArtistAgain(name) }
            .disabled(!isLookedUp || isLookingUp)
        if isConfirmed {
            Button("Not This Artist") { model.rejectArtistIdentity(name) }
                .disabled(isLookingUp)
        }
        Divider()
        if profile?.noPhoto == true {
            Button("Show Photo") { model.setArtistNoPhoto(name, false) }
        } else {
            Button("No Photo") { model.setArtistNoPhoto(name, true) }
        }
    }

    // MARK: - Name and facts

    private var caption: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(CarbonFont.sans(19, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu { portraitMenu } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .carbonTip("Look up again, or choose the photo")
            }
            if let line = stateLine {
                Text(Self.wrappingAtSeparators(line.text.uppercased()))
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(line.lit ? theme.orange : theme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(hairline, alignment: .bottom)
    }

    /// Spaces inside each fact made unbreakable, so a line too long for the
    /// inspector wraps between facts ("1965 to now" stays whole).
    private static func wrappingAtSeparators(_ text: String) -> String {
        text.components(separatedBy: " · ")
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: " · ")
    }

    /// The line under the name: the facts when there are any, else where
    /// the lookup stands. Lit while a lookup the owner asked for runs.
    private var stateLine: (text: String, lit: Bool)? {
        if isLookingUp { return ("Looking up…", true) }
        if uncertainCandidates != nil { return nil }
        if let line = ArtistPageText.factsLine(facts) { return (line, false) }
        guard isLookedUp else { return nil }
        switch profile?.identity ?? .unknown {
        case .unknown: return ("Not looked up yet", false)
        case .notFound: return ("Not found on MusicBrainz", false)
        case .rejected: return ("Not looked up: none of the matches", false)
        case .confirmed, .uncertain: return nil
        }
    }

    // MARK: - Is this them?

    private func identityQuestion(_ candidates: [ArtistIdentityCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Is this them?", tint: theme.orange)
            Text("MusicBrainz has more than one \(name). Pick the one in your library.")
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            ForEach(candidates, id: \.musicBrainzID) { candidate in
                Button { model.confirmArtistIdentity(name, musicBrainzID: candidate.musicBrainzID) } label: {
                    candidateRow(candidate)
                }
                .buttonStyle(.carbonHover)
                .disabled(isLookingUp)
            }
            Button { model.confirmArtistIdentity(name, musicBrainzID: nil) } label: {
                Text("NONE OF THESE")
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLookingUp)
            .carbonTip("Stop looking this artist up, until Look Up Again")
        }
        .padding(.bottom, 6)
    }

    private func candidateRow(_ candidate: ArtistIdentityCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(candidate.name)
                    .font(CarbonFont.sans(12, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                if let note = candidate.disambiguation, !note.isEmpty {
                    Text(note)
                        .font(CarbonFont.sans(11))
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                }
            }
            if let origin = candidate.origin, !origin.isEmpty {
                Text(origin.uppercased())
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
            if !candidate.releaseTitles.isEmpty {
                Text(candidate.releaseTitles.prefix(3).joined(separator: " · "))
                    .font(CarbonFont.sans(10.5))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Bio, members, genres

    @ViewBuilder
    private var bio: some View {
        if let text = facts.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let clamps = text.count > Self.bioClampLength
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(CarbonFont.sans(11.5))
                    .foregroundStyle(theme.ink2)
                    .lineSpacing(2)
                    .lineLimit(clamps && !bioExpanded ? 6 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if let source = facts.bioSourceURL {
                        Button { openURL(source) } label: {
                            HStack(spacing: 3) {
                                Text("From Wikipedia, CC BY-SA 4.0")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .font(CarbonFont.mono(8.5, weight: .semibold))
                            .foregroundStyle(theme.ink3)
                        }
                        .buttonStyle(.plain)
                        .carbonTip("Open the article on Wikipedia")
                    }
                    Spacer(minLength: 0)
                    if clamps {
                        Button(bioExpanded ? "LESS" : "MORE") { bioExpanded.toggle() }
                            .buttonStyle(.plain)
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(theme.orange)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(hairline, alignment: .bottom)
        }
    }

    @ViewBuilder
    private var members: some View {
        if let members = facts.members, !members.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Members")
                ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(member.name)
                            .font(CarbonFont.sans(11.5, weight: member.isCurrent ? .semibold : .regular))
                            .foregroundStyle(member.isCurrent ? theme.ink : theme.ink3)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let years = ArtistPageText.memberYears(member) {
                            Text(years.uppercased())
                                .font(CarbonFont.mono(9))
                                .foregroundStyle(member.isCurrent ? theme.ink3 : theme.ink4)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                }
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var genres: some View {
        if let genres = facts.genres, !genres.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Genres")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(genres.prefix(5)), id: \.self) { genre in
                        Text(genre.uppercased())
                            .font(CarbonFont.mono(8.5, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(theme.ink2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.ink.opacity(theme.isDark ? 0.10 : 0.06)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - In your library, Listening

    private var scopeTitle: String {
        switch model.artistSummaryScope {
        case .localCrate(let crate): return "In \(crate)"
        case .prepCrate: return "In the Prep Crate"
        default: return "In your library"
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        let rows = libraryRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(scopeTitle)
                specRows(rows)
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(hairline, alignment: .top)
        }
    }

    private var libraryRows: [(String, String)] {
        guard let summary, summary.trackCount > 0 else { return [] }
        var rows: [(String, String)] = [("Albums", "\(summary.albumCount)")]
        let time = ArtistPageText.duration(summary.totalSeconds)
        rows.append(("Tracks", ["\(summary.trackCount)", time].compactMap { $0 }.joined(separator: " · ")))
        if let formats = ArtistPageText.formats(summary) { rows.append(("Format", formats)) }
        if let first = summary.firstAdded {
            let latest = summary.latestAdded ?? first
            let a = Self.monthYear.string(from: first), b = Self.monthYear.string(from: latest)
            rows.append(("Added", a == b ? a : "\(a) to \(b)"))
        }
        if !summary.crateNames.isEmpty { rows.append(("Crates", summary.crateNames.joined(separator: " · "))) }
        return rows
    }

    @ViewBuilder
    private var listeningSection: some View {
        if let summary, summary.trackCount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Listening")
                if summary.totalPlays == 0 {
                    Text("NOT PLAYED YET")
                        .font(CarbonFont.mono(9, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(theme.ink3)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                } else {
                    specRows([("Plays", "\(summary.totalPlays)"),
                              ("Last played", summary.lastPlayed.map(Self.dayMonthYear.string(from:)) ?? "")]
                        .filter { !$0.1.isEmpty })
                    let top = summary.topTracks.compactMap { model.artistTopTracks[$0] }
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(top.enumerated()), id: \.element.track.id) { index, loaded in
                                topTrackRow(loaded, number: index + 1)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(hairline, alignment: .top)
        }
    }

    private func topTrackRow(_ loaded: LoadedTrack, number: Int) -> some View {
        let isNowPlaying = model.nowPlayingTrack?.track.id == loaded.track.id
        let plays = model.listeningStore?.stats(path: ListeningStore.key(for: loaded.track.fileURL))?.playCount ?? 0
        return Button { model.playTrack(id: loaded.track.id) } label: {
            HStack(spacing: 10) {
                Text(isNowPlaying ? "▸" : "\(number)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundStyle(isNowPlaying ? theme.orange : theme.ink4)
                    .frame(width: 16, alignment: .trailing)
                Text(loaded.track.title)
                    .font(CarbonFont.sans(11, weight: isNowPlaying ? .bold : .regular))
                    .foregroundStyle(isNowPlaying ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(plays)×")
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink4)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .background(isNowPlaying ? theme.orange.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Play")
    }

    // MARK: - Links

    @ViewBuilder
    private var linksRow: some View {
        let links = uncertainCandidates == nil ? (facts.links ?? []).filter { $0.kind != .other } : []
        HStack(spacing: 8) {
            ForEach(links, id: \.url) { link in
                Button { openURL(link.url) } label: {
                    HStack(spacing: 4) {
                        Text(link.kind == .musicBrainz ? "MUSICBRAINZ" : "WIKIPEDIA")
                        Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
                    }
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().stroke(theme.ink.opacity(theme.isDark ? 0.22 : 0.18), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .carbonTip("Open in your browser")
            }
            Spacer(minLength: 0)
            // Task 8: opens the Edit Artist sheet.
            Button("EDIT…") {}
                .buttonStyle(.plain)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink4)
                .disabled(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(hairline, alignment: .top)
    }

    // MARK: - Pieces

    private var hairline: some View {
        Rectangle()
            .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
            .frame(height: 1)
    }

    private func sectionHeader(_ title: String, tint: Color? = nil) -> some View {
        Text(title.uppercased())
            .font(CarbonFont.mono(9, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(tint ?? theme.ink3)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    /// The album page's spec rows (`SpecRows`), for the library's numbers.
    private func specRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(key.uppercased())
                        .font(CarbonFont.mono(9, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(theme.ink3)
                        .frame(width: Self.keyWidth, alignment: .leading)
                    Text(value)
                        .font(CarbonFont.mono(11, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

    private static let dayMonthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// The artist's default photo, square and as wide as the inspector, framed
/// like the album poster; the artist's initials on an unlit tile when there
/// is none, the owner asked for none, or its file cannot be reached.
private struct ArtistPortrait<MenuItems: View>: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let name: String
    let photo: ArtistPhoto?
    @ViewBuilder let menu: () -> MenuItems

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        // Task 9: a click opens the artist photo viewer.
        Button(action: {}) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(content)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .grainFree(cornerRadius: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.black.opacity(theme.isDark ? 0.6 : 0.18), lineWidth: 1)
                )
                .depthShadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.35), radius: 8, y: 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.orange)
                        .blur(radius: 14)
                        .opacity(hovering && image != nil ? 0.55 : 0)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CarbonMotion.hover, value: hovering)
        .contextMenu { menu() }
        .task(id: photo?.hash) {
            guard let hash = photo?.hash else {
                image = nil
                return
            }
            image = await model.artistPhotoThumbnail(hash: hash)
        }
        .accessibilityLabel(image == nil ? "No photo of \(name)" : "Photo of \(name)")
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            InitialsTile(name: name)
        }
    }
}

/// The Artist Pictures sheet's placeholder tile (a hue of the name's own,
/// its initials), unlit: darker and quieter, so it reads as "no photo"
/// rather than a picture. The hue is stable across launches.
private struct InitialsTile: View {
    let name: String

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.32, brightness: 0.38),
                                        Color(hue: hue, saturation: 0.45, brightness: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(ArtistPageText.initials(name))
                    .font(.system(size: proxy.size.width * 0.3, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }
}
