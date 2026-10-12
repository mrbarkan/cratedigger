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
    /// A search that failed (network, MusicBrainz busy). Kept apart from a
    /// search that worked and found nothing, which `searchedEmpty` says.
    @State private var searchError: String? = nil
    @State private var searchedEmpty = false
    /// The search in flight. A new search, or closing the sheet, cancels it,
    /// so a slow old query can't land over the results of a newer one.
    @State private var searchTask: Task<Void, Never>? = nil
    /// The remembered release opens by itself on the first search only. Doing
    /// it on every search threw the user back into the grid each time they
    /// searched again from the list.
    @State private var didOpenRemembered = false

    // Cover Art Archive counts for the release list
    /// Per release: counting, counted, or couldn't be counted. Filled a release
    /// group at a time from MusicBrainz, not a row at a time from archive.org.
    @State private var coverArtCounts: [String: CoverArtCount] = [:]
    @State private var countTask: Task<Void, Never>? = nil
    @State private var counting = false
    /// Front-cover size per release, measured as rows come on screen, and only
    /// for releases MusicBrainz says have a front.
    @State private var frontSizes: [String: ArtworkDimensions] = [:]
    @State private var frontProbeTask: Task<Void, Never>? = nil

    // The picked release's scans
    @State private var selectedReleaseID: String? = nil
    @State private var selectedReleaseTitle: String = ""
    @State private var caaImages: [RemoteArtworkImage] = []
    /// Image id → the original's true pixel size, filled in as probes land.
    @State private var imageDimensions: [String: ArtworkDimensions] = [:]
    /// Each source's progress for the picked release. The two load side by
    /// side: Discogs takes a MusicBrainz relation lookup, then a search, then
    /// the release, and the archive is served from archive.org, which can
    /// take twenty seconds. Neither waits for the other any more.
    @State private var archiveLoad: ArtworkSourceLoad = .idle
    @State private var discogsLoad: ArtworkSourceLoad = .idle
    /// The load in flight. BACK, another release, or closing cancels it.
    @State private var loadTask: Task<Void, Never>? = nil
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
    /// Relevance, year, or BEST ART: the art a release actually carries,
    /// which is the reason you are in this sheet at all.
    @State private var releaseSort: ArtworkReleaseSort = .relevance
    @State private var groupByRelease = false

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
        // Nothing this sheet started outlives it: a closed panel used to keep
        // probing and writing into state nobody could see.
        .onDisappear(perform: cancelAllWork)
        // The fade is scoped to the overlay. On the whole sheet it put the
        // release list and the grid inside any transaction that happened to
        // coincide with opening or closing the preview.
        .overlay {
            ZStack {
                if let preview = previewImage {
                    imagePreviewOverlay(preview)
                        .transition(.opacity)
                }
            }
            .animation(CarbonMotion.state, value: previewImage?.id)
        }
    }

    private func cancelAllWork() {
        searchTask?.cancel()
        countTask?.cancel()
        frontProbeTask?.cancel()
        loadTask?.cancel()
    }

    private func imagePreviewOverlay(_ img: RemoteArtworkImage) -> some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { previewImage = nil }

            VStack(spacing: 14) {
                // A large derivative where the archive has one, not the
                // original: the overlay is at most 560pt wide, and an original
                // can be a 5000px, multi-megabyte scan.
                ArtworkSearchImage(image: img, url: img.bestPreviewURL, maxPixelSize: 1200) {
                    ProgressView().controlSize(.large)
                } failure: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.6))
                }
                .aspectRatio(contentMode: .fit)
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
                KeyButton(style: .normal, action: leaveGrid) {
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
                .carbonTip("Include Discogs scans of the pressing you pick. They cover far more of a physical release, like the back, labels and inserts, but the lookup takes a few seconds. Off skips it entirely.")
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
                // Return searches, as in every other search field.
                .onSubmit(executeSearch)
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
    /// already drifted apart in size and tone. `retry` adds a TRY AGAIN key,
    /// for the states a second attempt can actually change.
    private func statusPanel(icon: String? = nil,
                             spinner: Bool = false,
                             tint: Color? = nil,
                             title: String,
                             detail: String,
                             retry: (() -> Void)? = nil) -> some View {
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
            if let retry {
                KeyButton(style: .normal, action: retry) {
                    Text("TRY AGAIN")
                }
                .frame(width: 96, height: 22)
                .padding(.top, 4)
            }
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
                            title: "Search failed", detail: error, retry: executeSearch)
            } else if searchedEmpty {
                statusPanel(icon: "magnifyingglass", title: "No releases found",
                            detail: "MusicBrainz has nothing under this artist and album. Try a shorter title, or check the spelling.")
            } else if mbReleases.isEmpty {
                statusPanel(icon: "music.note.list", title: "Nothing searched yet",
                            detail: "Enter an artist and album above, then press SEARCH.")
            } else {
                releaseList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list itself. What it draws is worked out once per render, in Core,
    /// rather than once per row.
    private var releaseList: some View {
        let displayed = ArtworkReleaseList.displayed(mbReleases, media: mediaFilter, country: countryFilter,
                                                     sort: releaseSort, counts: coverArtCounts,
                                                     frontSizes: frontSizes)
        let bestID = ArtworkReleaseList.bestMatchID(in: displayed, albumTitle: album.title,
                                                    albumYear: album.year, albumMedia: album.mediaFormat)
        return VStack(spacing: 0) {
            filterBar(shown: displayed.count)
            Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            if displayed.isEmpty {
                statusPanel(icon: "line.3.horizontal.decrease.circle", title: "Nothing matches the filters",
                            detail: "None of the \(mbReleases.count) releases matches both filters. Set MEDIA or COUNTRY back to All.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if groupByRelease {
                            ForEach(ArtworkReleaseList.grouped(displayed), id: \.edition) { group in
                                groupHeaderRow(group.edition, count: group.releases.count)
                                releaseRows(group.releases, bestID: bestID)
                            }
                        } else {
                            releaseRows(displayed, bestID: bestID)
                        }
                    }
                }
            }
        }
    }

    private func releaseRows(_ releases: [MBReleaseCandidate], bestID: String?) -> some View {
        ForEach(releases) { release in
            ArtworkReleaseRow(
                release: release,
                count: coverArtCounts[release.id] ?? .pending,
                frontSize: frontSizes[release.id],
                isBest: release.id == bestID,
                isRemembered: release.id == rememberedReleaseID,
                probeFront: { await probeFront(release.id) },
                open: { loadReleaseArtwork(release) }
            )
            .equatable()
            Divider().background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        }
    }

    // MARK: - Filter / sort / group

    private func filterBar(shown: Int) -> some View {
        HStack(spacing: 10) {
            filterMenu(label: "MEDIA", selection: $mediaFilter, options: ArtworkReleaseList.formats(in: mbReleases))
            filterMenu(label: "COUNTRY", selection: $countryFilter, options: ArtworkReleaseList.countries(in: mbReleases))
            Text(shown == mbReleases.count ? "\(shown) RELEASES" : "\(shown) OF \(mbReleases.count)")
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.ink4)
            if counting {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("COUNTING IMAGES")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.ink4)
                }
                .carbonTip("Asking MusicBrainz how many Cover Art Archive images each release has.")
            }
            Spacer()
            toggleChip("SORT BY YEAR", isOn: releaseSort == .year) {
                releaseSort = releaseSort == .year ? .relevance : .year
            }
            toggleChip("BEST ART", isOn: releaseSort == .art) {
                releaseSort = releaseSort == .art ? .relevance : .art
                if releaseSort == .art { probeAllFronts() }
            }
            .carbonTip("Order releases by the art they carry: the biggest front cover first, then the most images.")
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
        // `.button` + `.plain`, not `.borderlessButton`: the borderless style
        // hands the label to AppKit, which keeps only the image and the first
        // text, puts the chevron in front and clips the mono caps to its own
        // button height. Same fix as the zoom menu in AlbumArtworkViewer.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .opacity(options.isEmpty ? 0.4 : 1)
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

    // MARK: - Counts and cover sizes

    /// Count every result's images, a release group at a time, merging each
    /// batch in one write so the list redraws once per group, not per row.
    private func startCounting(_ releases: [MBReleaseCandidate]) {
        countTask?.cancel()
        var pending = coverArtCounts
        for release in releases where pending[release.id] == nil { pending[release.id] = .pending }
        coverArtCounts = pending
        counting = true
        let service = model.remoteArtworkService
        countTask = Task {
            for await batch in service.coverArtSummaries(for: releases) {
                guard !Task.isCancelled else { return }
                var merged = coverArtCounts
                for (id, summary) in batch { merged[id] = CoverArtCount(lookup: summary) }
                coverArtCounts = merged
                if releaseSort == .art { probeAllFronts() }
            }
            guard !Task.isCancelled else { return }
            counting = false
        }
    }

    /// The front cover's true pixel size, straight off the archive's `/front`
    /// redirect: a header read, not a download. The service caps how many run
    /// at once and remembers failures briefly, so rows scrolling past don't
    /// pile up requests.
    private func probeFront(_ releaseID: String) async {
        guard frontSizes[releaseID] == nil,
              let size = await model.remoteArtworkService.frontCoverDimensions(releaseMBID: releaseID)
        else { return }
        frontSizes[releaseID] = size
    }

    /// BEST ART sorts on the front's size, so it needs every front measured,
    /// not just the rows on screen. Only releases MusicBrainz says have a
    /// front are asked about.
    private func probeAllFronts() {
        let pending = mbReleases.map(\.id).filter { id in
            frontSizes[id] == nil && coverArtCounts[id]?.summary.map { $0.hasFront && !$0.darkened } == true
        }
        guard !pending.isEmpty else { return }
        frontProbeTask?.cancel()
        frontProbeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for id in pending { group.addTask { await probeFront(id) } }
            }
        }
    }

    // Artwork grid section
    @ViewBuilder
    private var artworkGridSection: some View {
        // Decided from both sources at once, so the grid never says "no scans"
        // while one of them is still looking.
        switch ArtworkGridStatus.resolve(imageCount: caaImages.count, archive: archiveLoad, discogs: discogsLoad) {
        case .grid:
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
        case .loading(let detail):
            statusPanel(spinner: true, title: "Fetching scans", detail: detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty(let detail):
            statusPanel(icon: "photo.on.rectangle", title: "No scans", detail: detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let detail):
            statusPanel(icon: "exclamationmark.triangle.fill", tint: theme.orange,
                        title: "Couldn't fetch scans", detail: detail, retry: retrySelectedRelease)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Source chips, each source's progress, and the selection controls.
    /// Discogs results land in this same grid rather than a place of their
    /// own: they are more scans of the pressing you already picked, not a
    /// second search.
    private var gridToolbar: some View {
        HStack(spacing: 8) {
            sourceChip(nil, label: "ALL", count: caaImages.count)
            ForEach(availableSources, id: \.self) { source in
                sourceChip(source, label: source.badge.uppercased(),
                           count: caaImages.filter { $0.source == source }.count)
            }

            sourceProgress("CAA", load: archiveLoad,
                           loadingTip: "Reading this release from the Cover Art Archive. Its scans will join the grid.")
            sourceProgress("DISCOGS", load: discogsLoad,
                           loadingTip: "Looking this pressing up on Discogs. Its scans will join the grid.")

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
                // Scoped to the chip, like SELECT ALL: clearing what you can
                // see must not quietly drop choices made under another source.
                selectedImages.subtract(displayedImages.map(\.id))
                selectionAnchorID = nil
            }
            Text("\(actionableImages.count)/\(displayedImages.count)")
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.ink4)
                .help("Tip: ⇧-click to select a range")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.chassisHi.opacity(0.3))
        .overlay(Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1), alignment: .bottom)
    }

    /// A source still loading shows a spinner; one that failed says so and
    /// offers another try, instead of quietly contributing nothing.
    @ViewBuilder
    private func sourceProgress(_ label: String, load: ArtworkSourceLoad, loadingTip: String) -> some View {
        switch load {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("\(label)…")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.ink4)
            }
            .carbonTip(loadingTip)
        case .failed(let message):
            Button(action: retrySelectedRelease) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold))
                    Text("\(label) FAILED")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1)
                }
                .foregroundStyle(theme.orange)
            }
            .buttonStyle(.carbonHover)
            .carbonTip("\(message) Click to try again.")
        case .idle, .loaded:
            EmptyView()
        }
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

    /// What the grid draws, and — through `ArtworkSelectionScope` — what every
    /// action in the toolbar applies to. One definition, so a chip can never
    /// again hide a tile from the eye while leaving it in reach of STAGE.
    private var displayedImages: [RemoteArtworkImage] {
        ArtworkSelectionScope.visible(caaImages, source: sourceFilter)
    }

    /// The visible images that are selected, in grid order.
    private var actionableImages: [RemoteArtworkImage] {
        ArtworkSelectionScope.actionable(caaImages, selected: selectedImages, source: sourceFilter)
    }

    private func artworkCell(_ img: RemoteArtworkImage) -> some View {
        let isSelected = selectedImages.contains(img.id)
        return VStack(spacing: 6) {
            Button(action: { handleImageTap(img) }) {
                ArtworkSearchImage(image: img, url: img.thumbnailURL, maxPixelSize: 300) {
                    ProgressView().controlSize(.small)
                } failure: {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundColor(.gray.opacity(0.55))
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 130, height: 130)
                .background(Color.gray.opacity(0.2))
                .clipped()
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
                            .carbonTip("Scan from Discogs. It holds far more of a physical release, like the back, labels and inserts, but doesn't say which is which, so pick the role yourself.")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let size = imageDimensions[img.id] {
                        let isHiRes = size.isHighResolution
                        Text(isHiRes ? "HD" : "\(size.width)×\(size.height)")
                            .font(CarbonFont.mono(7.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(isHiRes ? theme.cyan : Color.black.opacity(0.55)))
                            .padding(5)
                            .carbonTip("The original is \(size.width) × \(size.height) pixels")
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
        // The range runs through what is on screen. Indexing the unfiltered
        // list made a ⇧-click across two visible tiles sweep up every hidden
        // one that happened to sit between them.
        let visible = displayedImages
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = selectionAnchorID,
           let a = visible.firstIndex(where: { $0.id == anchor }),
           let b = visible.firstIndex(where: { $0.id == img.id }) {
            for i in min(a, b)...max(a, b) { selectSingle(visible[i]) }
        } else {
            toggleImageSelection(img)
            selectionAnchorID = img.id
        }
    }

    /// Everything the chip is showing. Under a filter this adds to whatever is
    /// already selected elsewhere rather than replacing it.
    private func selectAllImages() {
        for img in displayedImages { selectSingle(img) }
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
                .help("Fetches in the background. Carry on browsing; the ART tab shows the progress.")
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
        panel.message = "Pick images or a folder of scans. Roles are read from the filenames; "
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

        // Show what is about to be added. A source chip now scopes staging as
        // well as drawing, so adopting files under a filter that hides them
        // would tick them and then refuse to fetch them.
        sourceFilter = nil

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
        searchTask?.cancel()
        countTask?.cancel()
        leaveGrid()
        searching = true
        mbReleases = []
        searchError = nil
        searchedEmpty = false
        counting = false
        // New result set: drop filters that may no longer have matches, and
        // counts for releases that are no longer listed. The service keeps
        // its own cache, so a release that comes back is counted at once.
        mediaFilter = nil
        countryFilter = nil
        coverArtCounts = [:]

        let artist = artistQuery
        let albumTitle = albumQuery
        let service = model.remoteArtworkService
        let opensRemembered = !didOpenRemembered
        didOpenRemembered = true

        searchTask = Task {
            do {
                let results = try await service.searchMusicBrainzReleases(artist: artist, album: albumTitle)
                guard !Task.isCancelled else { return }
                mbReleases = results
                searching = false
                searchedEmpty = results.isEmpty
                startCounting(results)
                // Straight back to the pressing this album's art came from,
                // if it's still in the results. BACK TO RELEASES is one key
                // away when it isn't the one you want this time.
                if opensRemembered, let remembered = rememberedReleaseID,
                   let match = results.first(where: { $0.id == remembered }) {
                    loadReleaseArtwork(match)
                }
            } catch {
                guard !Task.isCancelled else { return }
                searching = false
                searchError = error.localizedDescription
            }
        }
    }

    /// Back to the release list: stop whatever the grid was loading and drop
    /// its images, selection and filter.
    private func leaveGrid() {
        loadTask?.cancel()
        loadTask = nil
        selectedReleaseID = nil
        selectedReleaseTitle = ""
        caaImages = []
        imageDimensions = [:]
        selectedImages = []
        imageRoles = [:]
        selectionAnchorID = nil
        sourceFilter = nil
        previewImage = nil
        archiveLoad = .idle
        discogsLoad = .idle
    }

    private func retrySelectedRelease() {
        guard let id = selectedReleaseID, let release = mbReleases.first(where: { $0.id == id }) else { return }
        loadReleaseArtwork(release)
    }

    private func loadReleaseArtwork(_ release: MBReleaseCandidate) {
        leaveGrid()
        selectedReleaseID = release.id
        selectedReleaseTitle = release.title + (release.disambiguation.map { " (\($0))" } ?? "")
        archiveLoad = .loading
        discogsLoad = includeDiscogs ? .loading : .idle

        let service = model.remoteArtworkService
        let artist = artistQuery
        let wantsDiscogs = includeDiscogs
        let token = PreferencesStore.shared.discogsToken

        // Both sources at once, each landing as it answers. They used to run
        // one after the other, so Discogs waited out archive.org's 10 to 20
        // seconds, and an archive error skipped Discogs altogether.
        loadTask = Task {
            // Settings can change the token between lookups.
            await service.setDiscogsToken(token)
            async let archive: Void = loadArchive(release, using: service)
            async let discogs: Void = wantsDiscogs ? loadDiscogs(release, artist: artist, using: service) : ()
            _ = await (archive, discogs)
        }
    }

    /// True while `release` is still the one on screen and this load hasn't
    /// been superseded. Picking another release, BACK, or picking the same
    /// one again all cancel the old load first.
    private func isCurrent(_ release: MBReleaseCandidate) -> Bool {
        !Task.isCancelled && selectedReleaseID == release.id
    }

    private func loadArchive(_ release: MBReleaseCandidate, using service: RemoteArtworkService) async {
        do {
            let images = try await service.fetchCoverArtArchiveImages(releaseMBID: release.id)
            guard isCurrent(release) else { return }
            // After any files from disk, ahead of any Discogs scans that got
            // here first: the archive's images are typed and come first.
            let known = Set(caaImages.map(\.id))
            let fresh = images.filter { !known.contains($0.id) }
            let insertAt = caaImages.firstIndex { $0.source == .discogs } ?? caaImages.count
            caaImages.insert(contentsOf: fresh, at: insertAt)
            archiveLoad = .loaded(count: images.count)
            await probeDimensions(for: fresh, using: service)
        } catch {
            guard isCurrent(release) else { return }
            archiveLoad = .failed(Self.archiveFailureMessage(error))
        }
    }

    private func loadDiscogs(_ release: MBReleaseCandidate, artist: String,
                             using service: RemoteArtworkService) async {
        // The whole candidate, not just its id: its barcode and year are what
        // find this pressing on Discogs when MusicBrainz hasn't linked the
        // two. A Discogs miss is not an error; the archive's images still
        // stand on their own.
        let images = await service.discogsImages(for: release, artist: artist)
        guard isCurrent(release) else { return }
        let known = Set(caaImages.map(\.id))
        let fresh = images.filter { !known.contains($0.id) }
        caaImages.append(contentsOf: fresh)
        discogsLoad = .loaded(count: images.count)
        await probeDimensions(for: fresh, using: service)
    }

    /// The archive's failures in words a person can act on. A timeout is the
    /// common one: the archive is served from archive.org, which can be slow.
    private static func archiveFailureMessage(_ error: Error) -> String {
        if case let RemoteArtworkService.FetchError.networkFailure(urlError) = error,
           urlError.code == .timedOut {
            return "The Cover Art Archive didn't answer in time. It is served from archive.org, which is sometimes slow."
        }
        return error.localizedDescription
    }

    /// Header-only probes; the service runs a few at a time, and the grid
    /// fills its size badges in as they land. Stops when the load is
    /// cancelled.
    private func probeDimensions(for images: [RemoteArtworkImage], using service: RemoteArtworkService) async {
        let remote = images.filter { $0.source != .localFile }
        await withTaskGroup(of: (String, ArtworkDimensions?).self) { group in
            for img in remote {
                group.addTask { (img.id, await service.probeDimensions(of: img.imageURL)) }
            }
            for await (id, dimensions) in group {
                guard !Task.isCancelled else { return }
                if let dimensions { imageDimensions[id] = dimensions }
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

        // Selected *and* on screen: a source chip scopes what is fetched, not
        // just what is drawn.
        let orderedSelected = actionableImages

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
