import SwiftUI
import AppKit
import CrateDiggerCore

/// Picker selection for an image's role. `.cover` is the embedded main cover;
/// `.altCover` is a secondary front kept alongside it. For multi-disc albums the
/// "CD" role fans out into a per-disc choice so each disc gets its own art — the
/// disc number is saved both into the filename (disc1.jpg, disc2.jpg, …) and
/// structurally into the manifest's `discNumbers` map.
private enum ArtRoleChoice: Hashable {
    case cover
    case altCover
    case back
    case disc(Int)
    case bookletPage
    case ignore
    /// Any other assignable role (spine, sleeve, sticker, matrix/runout, obi,
    /// inlay, poster, wrapped cover) — everything without disc-number handling.
    case role(ArtworkRole)

    /// The non-disc roles offered in the picker beyond the classic five, in
    /// ART-grid order.
    static var extendedChoices: [ArtworkRole] {
        ArtworkRole.assignable.filter {
            ![.cover, .altCover, .back, .disc, .bookletPage].contains($0)
        }
    }

    var role: ArtworkRole {
        switch self {
        case .cover: return .cover
        case .altCover: return .altCover
        case .back: return .back
        case .disc: return .disc
        case .bookletPage: return .bookletPage
        case .ignore: return .ignore
        case .role(let role): return role
        }
    }

    /// The CD/disc index for `.disc` choices; nil for every other role.
    var discNumber: Int? {
        if case let .disc(number) = self { return number }
        return nil
    }
}

struct ArtworkSearchSheetView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.carbonPanelDismiss) private var panelDismiss

    /// `\.dismiss` does nothing inside a hosted window; route through the panel.
    private func closePanel() {
        if let panelDismiss { panelDismiss() } else { dismiss() }
    }

    let album: Album

    // Search query state
    @State private var artistQuery: String
    @State private var albumQuery: String

    // Search state
    @State private var searching = false
    @State private var mbReleases: [MBReleaseCandidate] = []
    @State private var searchError: String? = nil

    // Cover Art Archive state
    @State private var loadingArt = false
    @State private var selectedReleaseID: String? = nil
    @State private var selectedReleaseTitle: String = ""
    @State private var caaImages: [RemoteArtworkImage] = []
    /// Image id → the original's true pixel size, filled in as probes land.
    @State private var imageDimensions: [String: ArtworkDimensions] = [:]
    @State private var artError: String? = nil
    /// Stage two of the image load. Discogs takes a MusicBrainz relation lookup,
    /// then a search, then the release — seconds, not milliseconds — so the grid
    /// says it's still coming instead of sprouting tiles unannounced.
    @State private var loadingDiscogs = false
    /// Session filter over the loaded images.
    @State private var sourceFilter: RemoteArtworkSource? = nil
    /// Off skips the Discogs stage entirely — no wait, no tiles. Persisted,
    /// because it's a taste about sources, not about this one album.
    @AppStorage("cratedigger.artwork.includeDiscogs") private var includeDiscogs = true

    // Image Selection state
    @State private var selectedImages: Set<String> = [] // imageURL string
    @State private var imageRoles: [String: ArtRoleChoice] = [:] // imageURL string to role choice
    /// Last plain-clicked image, so ⇧-click can select the contiguous range.
    @State private var selectionAnchorID: String? = nil

    // Full-size preview shown over the grid (does not affect selection).
    @State private var previewImage: RemoteArtworkImage? = nil

    // Result filtering / sorting / grouping (the release list).
    @State private var mediaFilter: String? = nil
    @State private var countryFilter: String? = nil
    @State private var sortByYear = false
    @State private var groupByRelease = false

    /// Cover Art Archive image count per release, probed lazily as rows become
    /// visible. Missing key = probe not finished; value nil = probe failed
    /// (network), shown as nothing rather than a false "no images".
    @State private var imageCounts: [String: Int?] = [:]
    /// Front-cover size per release, probed like the counts. Nil value = probed
    /// and it has no front, so the row can say so rather than stay blank.
    @State private var coverSizes: [String: ArtworkDimensions?] = [:]
    /// Order releases by the art they carry rather than by MusicBrainz's
    /// relevance — the reason you are in this sheet at all.
    @State private var sortByArt = false
    /// The release this album's artwork already came from, read from the
    /// manifest when the sheet opens.
    @State private var rememberedReleaseID: String?

    init(album: Album) {
        self.album = album
        _artistQuery = State(initialValue: album.artistName)
        _albumQuery = State(initialValue: album.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            
            if !showsGrid {
                searchBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(theme.chassisHi.opacity(0.5))
                
                Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            }
            
            contentArea
            
            Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            
            footer
        }
        .frame(minWidth: 0, idealWidth: 860, maxWidth: .infinity,
               minHeight: 0, idealHeight: 660, maxHeight: .infinity)
        .background(theme.chassis)
        .onAppear {
            rememberedReleaseID = album.tracks.first
                .map { $0.track.fileURL.deletingLastPathComponent() }
                .flatMap { ArtworkManifest.load(from: $0) }?
                .releaseMBID
            executeSearch()
        }
        .overlay {
            if let preview = previewImage {
                imagePreviewOverlay(preview)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewImage?.id)
    }

    private func imagePreviewOverlay(_ img: RemoteArtworkImage) -> some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { previewImage = nil }

            VStack(spacing: 14) {
                AsyncImage(url: img.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.6))
                    default:
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(maxWidth: 560, maxHeight: 480)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14), lineWidth: 1))
                .depthShadow(color: .black.opacity(0.6), radius: 22, y: 10)

                // Source, true pixel size and whatever the archive called it —
                // everything you need to judge a scan, on one line.
                HStack(spacing: 8) {
                    Text(img.source.badge.uppercased())
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(img.source == .discogs ? theme.indigo : theme.cyan))
                    if let size = imageDimensions[img.id] {
                        Text("\(size.width) × \(size.height)")
                            .font(CarbonFont.mono(9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    if !img.comment.isEmpty {
                        Text(img.comment)
                            .font(CarbonFont.sans(11))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                KeyButton(style: .normal, action: { previewImage = nil }) {
                    Text("CLOSE")
                }
                .frame(width: 90, height: 22)
            }
            .padding(30)
        }
    }

    // Header
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search Album Artwork".uppercased())
                    .font(CarbonFont.mono(11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.ink)
                Text(selectedReleaseID == nil
                     ? "MusicBrainz releases · Cover Art Archive · Discogs · your own scans"
                     : (selectedReleaseTitle.isEmpty ? "Files from disk" : selectedReleaseTitle))
                    .font(CarbonFont.sans(11))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
            Spacer()
            
            if showsGrid {
                KeyButton(style: .normal, action: {
                    self.selectedReleaseID = nil
                    self.caaImages = []
                    self.selectedImages = []
                    self.imageRoles = [:]
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                        Text("BACK TO RELEASES")
                    }
                }
                .frame(width: 130, height: 18)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    // Search bar
    private var searchBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            queryField("ARTIST", placeholder: "Artist", text: $artistQuery)
            queryField("ALBUM", placeholder: "Album", text: $albumQuery)

            KeyButton(style: .selected, action: executeSearch) {
                Text("SEARCH")
            }
            .frame(width: 80, height: 22)

            KeyButton(style: .normal, action: addFilesFromDisk) {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text("FILES")
                }
            }
            .frame(width: 80, height: 22)
            .carbonTip("Add your own scans. They land in the same grid as the online results, with their role read from the filename.")

            toggleChip("DISCOGS", isOn: includeDiscogs) { includeDiscogs.toggle() }
                .padding(.bottom, 1)
                .carbonTip("Include Discogs scans of the pressing you pick. They cover far more of a physical release — back, labels, inserts — but the lookup takes a few seconds. Off skips it entirely.")
        }
    }

    /// One query field, built once for both columns.
    ///
    /// The font and the field's height are pinned rather than intrinsic. These
    /// were two copies of the same block sizing themselves from their own
    /// contents, which is how the row ended up with the artist field sitting
    /// lower and shorter than the album field: anything that changes one
    /// string's line box — a glyph that falls back to another face, a themed
    /// typeface with different metrics — silently moved one column and not the
    /// other. A fixed line box can't drift, whatever is typed into it.
    private func queryField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(CarbonFont.mono(8, weight: .bold))
                .foregroundStyle(theme.ink3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(CarbonFont.sans(12))
                .lineLimit(1)
                .frame(height: 16)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
        }
    }

    /// One presentation for every "nothing to show yet" state in this sheet —
    /// searching, empty, failed. They were five hand-rolled stacks that had
    /// already drifted apart in size and tone.
    private func statusPanel(icon: String? = nil,
                             spinner: Bool = false,
                             tint: Color? = nil,
                             title: String,
                             detail: String) -> some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(tint ?? theme.ink4)
            }
            Text(title.uppercased())
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink2)
            Text(detail)
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(28)
    }

    // Content
    /// Local files are album-scoped, not release-scoped, so they can put the
    /// grid on screen with no release picked at all.
    private var hasLocalImages: Bool { caaImages.contains { $0.source == .localFile } }

    private var showsGrid: Bool { selectedReleaseID != nil || hasLocalImages }

    @ViewBuilder
    private var contentArea: some View {
        if showsGrid {
            artworkGridSection
        } else {
            releaseListSection
        }
    }

    // Release list section
    @ViewBuilder
    private var releaseListSection: some View {
        ZStack {
            if searching {
                statusPanel(spinner: true, title: "Searching MusicBrainz",
                            detail: "Looking for releases that match this album.")
            } else if let error = searchError {
                statusPanel(icon: "exclamationmark.triangle.fill", tint: theme.orange,
                            title: "No results", detail: error)
            } else if mbReleases.isEmpty {
                statusPanel(icon: "music.note.list", title: "Nothing searched yet",
                            detail: "Enter an artist and album above, then press SEARCH.")
            } else {
                VStack(spacing: 0) {
                    filterBar
                    Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if groupByRelease {
                                ForEach(groupedReleases, id: \.0) { group in
                                    groupHeaderRow(group.0, count: group.1.count)
                                    ForEach(group.1) { release in
                                        releaseRow(release)
                                        Divider().background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                    }
                                }
                            } else {
                                ForEach(displayedReleases) { release in
                                    releaseRow(release)
                                    Divider().background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter / sort / group

    private var filterBar: some View {
        HStack(spacing: 10) {
            filterMenu(label: "MEDIA", selection: $mediaFilter, options: distinctFormats)
            filterMenu(label: "COUNTRY", selection: $countryFilter, options: distinctCountries)
            Spacer()
            toggleChip("SORT BY YEAR", isOn: sortByYear) {
                sortByYear.toggle()
                if sortByYear { sortByArt = false }
            }
            toggleChip("BEST ART", isOn: sortByArt) {
                sortByArt.toggle()
                if sortByArt {
                    sortByYear = false
                    probeAllCovers()
                }
            }
            .carbonTip("Order releases by the front cover they actually carry, biggest first.")
            toggleChip("GROUP", isOn: groupByRelease) { groupByRelease.toggle() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.chassisHi.opacity(0.3))
    }

    private func filterMenu(label: String, selection: Binding<String?>, options: [String]) -> some View {
        Menu {
            Button("All") { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.self) { opt in
                Button(action: { selection.wrappedValue = opt }) {
                    if selection.wrappedValue == opt {
                        Label(opt, systemImage: "checkmark")
                    } else {
                        Text(opt)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label + ":")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(theme.ink3)
                Text(selection.wrappedValue ?? "All")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .foregroundStyle(selection.wrappedValue == nil ? theme.ink3 : theme.orange)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.ink4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .opacity(options.isEmpty ? 0.4 : 1)
    }

    /// Best art first: releases whose front cover measured largest, then those
    /// with the most images, then the unprobed. Probing is lazy per row, so
    /// this improves as rows scroll into view.
    private func byArtQuality(_ lhs: MBReleaseCandidate, _ rhs: MBReleaseCandidate) -> Bool {
        let left = (coverSizes[lhs.id] ?? nil)?.longEdge ?? 0
        let right = (coverSizes[rhs.id] ?? nil)?.longEdge ?? 0
        if left != right { return left > right }
        return ((imageCounts[lhs.id] ?? nil) ?? 0) > ((imageCounts[rhs.id] ?? nil) ?? 0)
    }

    private func toggleChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(isOn ? theme.orange : theme.ink3)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? theme.orange.opacity(0.15) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn ? theme.orange.opacity(0.5) : theme.ink4.opacity(0.25), lineWidth: 0.8))
        }
        .buttonStyle(.carbonHover)
    }

    private func groupHeaderRow(_ edition: String, count: Int) -> some View {
        HStack {
            Text(edition.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(theme.orange)
            Spacer()
            Text("\(count)")
                .font(CarbonFont.mono(9, weight: .bold))
                .foregroundStyle(theme.ink4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(theme.chassisHi.opacity(0.5))
    }

    private var distinctFormats: [String] {
        Array(Set(mbReleases.compactMap { $0.format })).sorted()
    }

    private var distinctCountries: [String] {
        Array(Set(mbReleases.compactMap { $0.country })).sorted()
    }

    /// `mbReleases` after media/country filters and optional year sort.
    private var displayedReleases: [MBReleaseCandidate] {
        var releases = mbReleases
        if let media = mediaFilter { releases = releases.filter { $0.format == media } }
        if let country = countryFilter { releases = releases.filter { $0.country == country } }
        if sortByArt {
            releases.sort(by: byArtQuality)
        } else if sortByYear {
            releases.sort { (yearValue($0) ?? Int.max) < (yearValue($1) ?? Int.max) }
        }
        return releases
    }

    /// Displayed releases grouped by edition, "Standard" first then alphabetical.
    private var groupedReleases: [(String, [MBReleaseCandidate])] {
        Dictionary(grouping: displayedReleases, by: { edition(of: $0) })
            .sorted { lhs, rhs in
                if lhs.key == "Standard" { return true }
                if rhs.key == "Standard" { return false }
                return lhs.key < rhs.key
            }
            .map { ($0.key, $0.value) }
    }

    private func yearValue(_ release: MBReleaseCandidate) -> Int? {
        guard let year = release.date?.split(separator: "-").first else { return nil }
        return Int(year)
    }

    /// A coarse edition label from the title + disambiguation keywords. Order
    /// matters — "super deluxe" before "deluxe", "remaster" catches remastered.
    private func edition(of release: MBReleaseCandidate) -> String {
        let hay = (release.title + " " + (release.disambiguation ?? "")).lowercased()
        let map: [(String, String)] = [
            ("anniversary", "Anniversary"),
            ("super deluxe", "Deluxe"),
            ("deluxe", "Deluxe"),
            ("remaster", "Remastered"),
            ("expanded", "Expanded"),
            ("special", "Special Edition"),
            ("collector", "Collector's"),
            ("limited", "Limited"),
            ("bonus", "Bonus"),
            ("reissue", "Reissue"),
            ("mono", "Mono")
        ]
        for (needle, label) in map where hay.contains(needle) { return label }
        return "Standard"
    }

    /// The release that best matches the album we're finding art for — badged so
    /// the user reaches for the right edition. Scored on metadata only (title,
    /// official status, format, year); Cover Art Archive image counts aren't in
    /// the MusicBrainz search response, so factoring them in would cost a fetch
    /// per edition. Nil unless something scores a real title match.
    private var bestReleaseID: String? {
        guard let best = displayedReleases.max(by: { releaseScore($0) < releaseScore($1) }),
              releaseScore(best) >= 40 else { return nil }
        return best.id
    }

    private func releaseScore(_ r: MBReleaseCandidate) -> Int {
        var score = 0
        let want = album.title.lowercased().trimmingCharacters(in: .whitespaces)
        let got = r.title.lowercased().trimmingCharacters(in: .whitespaces)
        if got == want {
            score += 100
        } else if !want.isEmpty && (got.contains(want) || want.contains(got)) {
            score += 40
        }
        if r.status == "Official" { score += 30 }
        if let fmt = r.format?.lowercased() {
            switch album.mediaFormat {
            case .some(.cd) where fmt.contains("cd"): score += 20
            case .some(.vinyl) where fmt.contains("vinyl") || fmt.contains("lp"): score += 20
            default: break
            }
        }
        if let y = album.year, let ry = yearValue(r) {
            if ry == y { score += 25 } else if abs(ry - y) <= 1 { score += 10 }
        }
        return score
    }

    private func releaseRow(_ release: MBReleaseCandidate) -> some View {
        let isBest = release.id == bestReleaseID
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isBest {
                        Text("★ BEST")
                            .font(CarbonFont.mono(8, weight: .bold))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.orange)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                            .carbonTip("Closest match to this album's title, format and year")
                    }
                    Text(release.title)
                        .font(CarbonFont.sans(12, weight: .bold))
                        .foregroundStyle(theme.ink)
                    if let format = release.format {
                        Text(format.uppercased())
                            .font(CarbonFont.mono(8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(theme.orange.opacity(0.15))
                            .foregroundColor(theme.orange)
                            .cornerRadius(3)
                    }
                    if let status = release.status, status != "Official" {
                        Text(status.uppercased())
                            .font(CarbonFont.mono(8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(theme.ink4.opacity(0.15))
                            .foregroundColor(theme.ink3)
                            .cornerRadius(3)
                    }
                }
                
                HStack(spacing: 12) {
                    if let date = release.date {
                        Text(date)
                            .font(CarbonFont.mono(9, weight: .medium))
                            .foregroundStyle(theme.ink3)
                    }
                    if let country = release.country {
                        Text("Country: \(country)")
                            .font(CarbonFont.mono(9, weight: .medium))
                            .foregroundStyle(theme.ink3)
                    }
                    if let tracks = release.trackCount {
                        Text("\(tracks) Tracks")
                            .font(CarbonFont.mono(9, weight: .medium))
                            .foregroundStyle(theme.ink3)
                    }
                    if let barcode = release.barcode {
                        Text("Barcode: \(barcode)")
                            .font(CarbonFont.mono(9, weight: .medium))
                            .foregroundStyle(theme.ink4)
                    }
                }
                
                if let disambiguation = release.disambiguation {
                    Text(disambiguation)
                        .font(CarbonFont.sans(9.5, weight: .regular))
                        .foregroundStyle(theme.ink3)
                        .italic()
                }
            }
            
            Spacer()

            if release.id == rememberedReleaseID {
                Text("USED")
                    .font(CarbonFont.mono(7.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.cyan))
                    .carbonTip("This album's artwork already came from this release.")
            }

            coverSizeBadge(release)
            imageCountBadge(release)

            KeyButton(style: .normal, action: {
                loadReleaseArtwork(release)
            }) {
                Text("GET ARTWORK")
            }
            .frame(width: 96, height: 22)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isBest ? theme.orange.opacity(0.06) : Color.clear)
        // Probe the CAA image count only once this row is on screen (LazyVStack)
        // — a full result set would otherwise fire 30 requests up front.
        .task(id: release.id) {
            guard !imageCounts.keys.contains(release.id) else { return }
            let count = await model.remoteArtworkService.coverArtImageCount(releaseMBID: release.id)
            imageCounts[release.id] = count
            await probeCover(release.id)
        }
    }

    /// The front cover's true pixel size, straight off the archive's `/front`
    /// redirect — a header read, not a download, so a whole result set costs
    /// about as much as the count probes already do.
    private func probeCover(_ releaseID: String) async {
        guard !coverSizes.keys.contains(releaseID),
              let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front")
        else { return }
        let size = await model.remoteArtworkService.probeDimensions(of: url)
        coverSizes[releaseID] = size
    }

    /// Sorting by art needs every row measured, not just the visible ones.
    private func probeAllCovers() {
        let pending = displayedReleases.map(\.id).filter { !coverSizes.keys.contains($0) }
        guard !pending.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in pending { group.addTask { await probeCover(id) } }
            }
        }
    }

    /// The front cover's size, once known. "HD" reads faster than the numbers
    /// when you're scanning a list for the one worth opening.
    @ViewBuilder
    private func coverSizeBadge(_ release: MBReleaseCandidate) -> some View {
        if let probed = coverSizes[release.id], let size = probed {
            let isHiRes = size.longEdge >= 1000
            Text(isHiRes ? "HD" : "\(size.longEdge)px")
                .font(CarbonFont.mono(7.5, weight: .bold))
                .tracking(0.5)
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(isHiRes ? theme.cyan : theme.ink3))
                .carbonTip("Front cover is \(size.width)×\(size.height) pixels")
        }
    }

    /// "N IMAGES" per release so the user knows which edition is worth opening.
    /// "…" while the probe is in flight; silent if the lookup failed.
    @ViewBuilder
    private func imageCountBadge(_ release: MBReleaseCandidate) -> some View {
        if let probed = imageCounts[release.id] {
            if let count = probed {
                Text(count == 0 ? "NO IMAGES" : "\(count) IMAGE\(count == 1 ? "" : "S")")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(count == 0 ? theme.ink4.opacity(0.12) : theme.cyan.opacity(0.15))
                    .foregroundColor(count == 0 ? theme.ink4 : theme.cyan)
                    .cornerRadius(3)
                    .carbonTip(count == 0
                        ? "The Cover Art Archive has no scans for this release"
                        : "Scans available in the Cover Art Archive")
            }
        } else {
            Text("…")
                .font(CarbonFont.mono(8, weight: .bold))
                .foregroundStyle(theme.ink4)
        }
    }

    // Artwork grid section
    @ViewBuilder
    private var artworkGridSection: some View {
        ZStack {
            if loadingArt {
                statusPanel(spinner: true, title: "Fetching scans",
                            detail: "Reading this release from the Cover Art Archive.")
            } else if let error = artError {
                statusPanel(icon: "exclamationmark.triangle.fill", tint: theme.orange,
                            title: "Nothing found", detail: error)
            } else if caaImages.isEmpty {
                statusPanel(icon: "photo.on.rectangle", title: "No scans",
                            detail: "This release has no artwork on the Cover Art Archive.")
            } else {
                VStack(spacing: 0) {
                    gridToolbar

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], spacing: 16) {
                            ForEach(displayedImages) { img in
                                artworkCell(img)
                            }
                        }
                        .padding(18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Source chips, the Discogs stage, and the selection controls. Discogs
    /// results land in this same grid rather than a place of their own — they
    /// are more scans of the pressing you already picked, not a second search.
    private var gridToolbar: some View {
        HStack(spacing: 8) {
            sourceChip(nil, label: "ALL", count: caaImages.count)
            ForEach(availableSources, id: \.self) { source in
                sourceChip(source, label: source.badge.uppercased(),
                           count: caaImages.filter { $0.source == source }.count)
            }

            if loadingDiscogs {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("DISCOGS…")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.ink4)
                }
                .carbonTip("Looking this pressing up on Discogs — its scans will join the grid.")
            }

            KeyButton(style: .normal, action: addFilesFromDisk) {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text("FILES")
                }
            }
            .frame(width: 74, height: 20)
            .carbonTip("Add your own scans to this grid")

            Spacer(minLength: 8)

            selectionButton("SELECT ALL") { selectAllImages() }
            selectionButton("NONE") {
                selectedImages = []
                selectionAnchorID = nil
            }
            Text("\(selectedImages.count)/\(caaImages.count)")
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.ink4)
                .help("Tip: ⇧-click to select a range")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.chassisHi.opacity(0.3))
        .overlay(Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1), alignment: .bottom)
    }

    private func sourceChip(_ source: RemoteArtworkSource?, label: String, count: Int) -> some View {
        toggleChip("\(label) \(count)", isOn: sourceFilter == source) {
            sourceFilter = (sourceFilter == source) ? nil : source
        }
        .disabled(count == 0 && source != nil)
        .opacity(count == 0 && source != nil ? 0.4 : 1)
    }

    private var availableSources: [RemoteArtworkSource] {
        var seen: [RemoteArtworkSource] = []
        for image in caaImages where !seen.contains(image.source) { seen.append(image.source) }
        return seen
    }

    private var displayedImages: [RemoteArtworkImage] {
        guard let sourceFilter else { return caaImages }
        return caaImages.filter { $0.source == sourceFilter }
    }

    private func artworkCell(_ img: RemoteArtworkImage) -> some View {
        let isSelected = selectedImages.contains(img.id)
        return VStack(spacing: 6) {
            Button(action: { handleImageTap(img) }) {
                AsyncImage(url: img.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 130, height: 130)
                            .clipped()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 130, height: 130)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 22))
                                    .foregroundColor(.gray.opacity(0.55))
                            )
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 130, height: 130)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? theme.orange : (theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)), lineWidth: isSelected ? 2 : 1)
                )
                .depthShadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
                .overlay(alignment: .bottomLeading) {
                    if img.source == .discogs {
                        Text(img.source.badge)
                            .font(CarbonFont.mono(7, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(theme.indigo.opacity(0.9)))
                            .padding(5)
                            .carbonTip("Scan from Discogs. It holds far more of a physical release — back, labels, inserts — but doesn't say which is which, so pick the role yourself.")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let size = imageDimensions[img.id] {
                        let isHiRes = min(size.width, size.height) >= 1000
                        Text(isHiRes ? "HD" : "\(size.width)×\(size.height)")
                            .font(CarbonFont.mono(7.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(isHiRes ? theme.cyan : Color.black.opacity(0.55)))
                            .padding(5)
                            .carbonTip("Original is \(size.width)×\(size.height) pixels")
                    }
                }
            }
            .buttonStyle(.plain)
            // The two corner icons are *overlays* on the select button, each with
            // its hit region clipped to the circle you can see. They used to be
            // ZStack siblings, one of them stretched to a full 130×130 frame — so
            // a click in the corner resolved against the tile's own tap target
            // instead of the icon, and expand only ever toggled selection.
            .overlay(alignment: .topLeading) {
                Button(action: { handleImageTap(img) }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? theme.orange : .white)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                        .clipShape(Circle())
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.carbonHover)
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: { previewImage = img }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.carbonHover)
                .padding(6)
                .carbonTip("Preview full size")
            }

            // Classification badge
            if !img.types.isEmpty {
                Text(img.types.joined(separator: ", ").uppercased())
                    .font(CarbonFont.mono(7.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                    .foregroundColor(theme.ink2)
                    .cornerRadius(3)
                    .lineLimit(1)
            }
            
            if !img.comment.isEmpty {
                Text(img.comment)
                    .font(CarbonFont.sans(8.5, weight: .regular))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Picker("", selection: Binding(
                get: { imageRoles[img.id] ?? defaultRole(for: img.types) },
                set: { imageRoles[img.id] = $0 }
            )) {
                Text("Main Cover").tag(ArtRoleChoice.cover)
                Text("Alt Cover").tag(ArtRoleChoice.altCover)
                Text("Back").tag(ArtRoleChoice.back)
                if album.discCount > 1 {
                    ForEach(1...album.discCount, id: \.self) { disc in
                        Text("CD \(disc)").tag(ArtRoleChoice.disc(disc))
                    }
                } else {
                    Text("Disc / CD").tag(ArtRoleChoice.disc(1))
                }
                Text("Booklet Page").tag(ArtRoleChoice.bookletPage)
                ForEach(ArtRoleChoice.extendedChoices, id: \.self) { role in
                    Text(role.displayName).tag(ArtRoleChoice.role(role))
                }
                Text("Ignore").tag(ArtRoleChoice.ignore)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(!isSelected)
        }
        .frame(width: 140)
    }

    /// CAA's own `types` tags drive the preselected role — a Matrix/Runout
    /// scan arrives as Matrix / Runout, a hype sticker as Sticker, and so on
    /// (mapping in `ArtworkRole.forCAATypes`).
    private func defaultRole(for types: [String]) -> ArtRoleChoice {
        switch ArtworkRole.forCAATypes(types) {
        case .cover: return .cover
        case .altCover: return .altCover
        case .back: return .back
        case .disc: return .disc(1)
        case .bookletPage: return .bookletPage
        case .ignore: return .ignore
        case let other: return .role(other)
        }
    }

    private func toggleImageSelection(_ img: RemoteArtworkImage) {
        if selectedImages.contains(img.id) {
            selectedImages.remove(img.id)
        } else {
            selectSingle(img)
        }
    }

    /// Add one image to the selection and seed its default role.
    private func selectSingle(_ img: RemoteArtworkImage) {
        selectedImages.insert(img.id)
        if imageRoles[img.id] == nil {
            imageRoles[img.id] = defaultRole(for: img.types)
        }
    }

    /// Plain click toggles one image and moves the ⇧-anchor there; ⇧-click adds
    /// the contiguous range from the anchor to the clicked cell (grid order).
    private func handleImageTap(_ img: RemoteArtworkImage) {
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = selectionAnchorID,
           let a = caaImages.firstIndex(where: { $0.id == anchor }),
           let b = caaImages.firstIndex(where: { $0.id == img.id }) {
            for i in min(a, b)...max(a, b) { selectSingle(caaImages[i]) }
        } else {
            toggleImageSelection(img)
            selectionAnchorID = img.id
        }
    }

    private func selectAllImages() {
        for img in caaImages { selectSingle(img) }
    }

    private func selectionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.orange.opacity(0.4), lineWidth: 0.8))
        }
        .buttonStyle(.carbonHover)
    }

    // Footer
    private var footer: some View {
        HStack {
            Spacer()
            
            KeyButton(style: .normal, action: { closePanel() }) {
                Text("CANCEL")
            }
            .frame(width: 90, height: geometry.keyHeight)
            
            if showsGrid {
                let downloads = compileDownloads()
                KeyButton(style: downloads.isEmpty ? .disabled : .selected, action: executeDownload) {
                    Text("STAGE \(downloads.count) IMAGE\(downloads.count == 1 ? "" : "S")")
                }
                .frame(width: 140, height: geometry.keyHeight)
                .help("Fetches in the background — carry on browsing, the ART tab shows the progress")
            }
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    // MARK: - Files from disk
    //
    // The disk path used to be its own key that imported straight to the album
    // folder with no review. Now it feeds the same grid the online results do:
    // one window, one role picker, one IMPORT — and you see what you're about
    // to write before it's written.

    private func addFilesFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.title = "Add artwork"
        panel.message = "Pick images or a folder of scans. Roles are read from the filenames — "
            + "anything unrecognised becomes a booklet page, or the cover if it's the only image."
        panel.prompt = "Add Artwork"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = ArtworkInspectorView.expandToImageFiles(panel.urls)
        guard !files.isEmpty else {
            model.appAlert = .error(title: "No Images Found",
                                    message: "Nothing in that selection was an image CrateDigger can read.")
            return
        }
        adopt(files)
    }

    /// Turn picked files into grid candidates: pre-selected (you already chose
    /// them in the panel), with the role their filename implies.
    private func adopt(_ files: [URL]) {
        // One unlabelled image is someone picking a cover; in a batch it's far
        // more likely to be a booklet page. Same rule the old key used.
        let single = files.count == 1
        let existing = Set(caaImages.map(\.id))

        for url in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let image = RemoteArtworkImage(
                imageURL: url,
                thumbnailURL: url,
                types: [],
                comment: url.lastPathComponent,
                front: false,
                back: false,
                source: .localFile
            )
            guard !existing.contains(image.id) else { continue }

            let role = ArtworkRole.inferred(fromFilename: url.lastPathComponent) ?? (single ? .cover : .bookletPage)
            imageRoles[image.id] = choice(for: role)
            selectedImages.insert(image.id)
            imageDimensions[image.id] = ArtworkQuality.pixelSize(ofImageAt: url)
            // Disk files go first: they're what you just asked for.
            caaImages.insert(image, at: caaImages.filter { $0.source == .localFile }.count)
        }
    }

    /// The picker choice standing for a role, so an inferred `.disc` still
    /// lands on the album's first disc rather than a bare role.
    private func choice(for role: ArtworkRole) -> ArtRoleChoice {
        switch role {
        case .cover:       return .cover
        case .altCover:    return .altCover
        case .back:        return .back
        case .disc:        return .disc(1)
        case .bookletPage: return .bookletPage
        case .ignore:      return .ignore
        default:           return .role(role)
        }
    }

    // Actions
    private func executeSearch() {
        searching = true
        mbReleases = []
        searchError = nil
        selectedReleaseID = nil
        caaImages = []
        // New result set → drop filters that may no longer have matches.
        mediaFilter = nil
        countryFilter = nil
        
        let artist = artistQuery
        let albumTitle = albumQuery
        
        Task {
            do {
                let results = try await model.remoteArtworkService.searchMusicBrainzReleases(
                    artist: artist,
                    album: albumTitle
                )
                await MainActor.run {
                    self.mbReleases = results
                    self.searching = false
                    if results.isEmpty {
                        self.searchError = "No releases found on MusicBrainz. Try adjusting artist or album name."
                    }
                    // Straight back to the pressing this album's art came from,
                    // if it's still in the results. BACK TO RELEASES is one key
                    // away when it isn't the one you want this time.
                    if let remembered = self.rememberedReleaseID,
                       let match = results.first(where: { $0.id == remembered }) {
                        self.loadReleaseArtwork(match)
                    }
                }
            } catch {
                await MainActor.run {
                    self.searching = false
                    self.searchError = error.localizedDescription
                }
            }
        }
    }

    private func loadReleaseArtwork(_ release: MBReleaseCandidate) {
        selectedReleaseID = release.id
        selectedReleaseTitle = release.title + (release.disambiguation.map { " (\($0))" } ?? "")
        loadingArt = true
        loadingDiscogs = includeDiscogs
        caaImages = []
        imageDimensions = [:]
        artError = nil
        selectedImages = []
        imageRoles = [:]
        sourceFilter = nil

        Task {
            do {
                let service = model.remoteArtworkService
                // Settings can change the token between lookups.
                await service.setDiscogsToken(PreferencesStore.shared.discogsToken)

                // Two stages, not one call. Finding a release on Discogs can
                // take several seconds (a MusicBrainz relation lookup, then a
                // search, then the release itself), and the archive's images
                // are usually one fast request away — so they go on screen
                // straight away rather than behind the slower source.
                let archive = try await service.fetchCoverArtArchiveImages(releaseMBID: release.id)
                await MainActor.run {
                    self.caaImages = archive
                    self.loadingArt = false
                }
                await probeDimensions(for: archive, using: service)

                // The whole candidate, not just its id: its barcode and year are
                // what find this pressing on Discogs when MusicBrainz hasn't
                // linked the two. A Discogs miss is not an error — the archive's
                // images still stand on their own.
                guard includeDiscogs else {
                    await MainActor.run {
                        if self.caaImages.isEmpty {
                            self.artError = "The Cover Art Archive has no images for this release."
                        }
                    }
                    return
                }

                let known = Set(archive.map(\.id))
                let discogs = await service.discogsImages(for: release, artist: artistQuery)
                    .filter { !known.contains($0.id) }
                await MainActor.run {
                    guard self.selectedReleaseID == release.id else { return }   // moved on already
                    self.loadingDiscogs = false
                    self.caaImages.append(contentsOf: discogs)
                    if self.caaImages.isEmpty {
                        self.artError = "Neither the Cover Art Archive nor Discogs has images for this release."
                    }
                }
                await probeDimensions(for: discogs, using: service)
            } catch {
                await MainActor.run {
                    self.loadingArt = false
                    self.loadingDiscogs = false
                    self.artError = error.localizedDescription
                }
            }
        }
    }

    /// Header-only probes, in parallel — the grid fills its size badges in as
    /// they land.
    private func probeDimensions(for images: [RemoteArtworkImage], using service: RemoteArtworkService) async {
        await withTaskGroup(of: (String, ArtworkDimensions?).self) { group in
            for img in images {
                group.addTask { (img.id, await service.probeDimensions(of: img.imageURL)) }
            }
            for await (id, dimensions) in group {
                guard let dimensions else { continue }
                await MainActor.run { self.imageDimensions[id] = dimensions }
            }
        }
    }

    private func getSuggestedFilename(for image: RemoteArtworkImage, index: Int, choice: ArtRoleChoice) -> String {
        let ext = image.imageURL.pathExtension.isEmpty ? "jpg" : image.imageURL.pathExtension.lowercased()
        switch choice {
        case .cover:
            return index == 0 ? "cover.\(ext)" : "cover_\(index + 1).\(ext)"
        case .altCover:
            return index == 0 ? "cover_alt.\(ext)" : "cover_alt_\(index + 1).\(ext)"
        case .back:
            return index == 0 ? "back.\(ext)" : "back_\(index + 1).\(ext)"
        case .disc:
            // Multi-disc albums get disc-numbered names (disc1.jpg, disc2.jpg);
            // single-disc albums keep the plain "disc" name.
            let base = album.discCount > 1 ? "disc\(choice.discNumber ?? 1)" : "disc"
            return index == 0 ? "\(base).\(ext)" : "\(base)_\(index + 1).\(ext)"
        case .bookletPage:
            return String(format: "booklet_%02d.\(ext)", index + 1)
        case .ignore:
            return "ignored_\(index + 1).\(ext)"
        case .role(let role):
            let base = role.suggestedFilenameBase
            return index == 0 ? "\(base).\(ext)" : "\(base)_\(index + 1).\(ext)"
        }
    }

    private func compileDownloads() -> [(url: URL, role: ArtworkRole, suggestedFilename: String, discNumber: Int?)] {
        var downloads: [(url: URL, role: ArtworkRole, suggestedFilename: String, discNumber: Int?)] = []
        var choiceCounts: [ArtRoleChoice: Int] = [:]

        let orderedSelected = caaImages.filter { selectedImages.contains($0.id) }

        for img in orderedSelected {
            let choice = imageRoles[img.id] ?? defaultRole(for: img.types)
            let count = choiceCounts[choice, default: 0]
            choiceCounts[choice] = count + 1

            let filename = getSuggestedFilename(for: img, index: count, choice: choice)
            downloads.append((url: img.imageURL, role: choice.role, suggestedFilename: filename, discNumber: choice.discNumber))
        }
        return downloads
    }

    /// Hand the fetch off and get out of the way.
    ///
    /// Staged, not imported: the ART tab is where you look at these and decide,
    /// and its SAVE is what puts them in the album folder. The download itself
    /// runs in the background — a full Cover Art Archive release is dozens of
    /// scans, and holding the window hostage for it bought the user nothing.
    private func executeDownload() {
        let downloads = compileDownloads()
        guard !downloads.isEmpty else { return }
        model.stageArtworkInBackground(images: downloads, for: album,
                                       releaseMBID: selectedReleaseID)
        closePanel()
    }
}
