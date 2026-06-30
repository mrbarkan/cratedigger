import SwiftUI
import CrateDiggerCore

/// Picker selection for an image's role. For multi-disc albums the "Disc" role
/// fans out into a per-disc choice so each disc can get its own art. The disc
/// number is carried into the saved filename (disc1.jpg, disc2.jpg, …); the
/// stored manifest role stays `.disc`.
private enum ArtRoleChoice: Hashable {
    case cover
    case back
    case disc(Int)
    case bookletPage
    case ignore

    var role: ArtworkRole {
        switch self {
        case .cover: return .cover
        case .back: return .back
        case .disc: return .disc
        case .bookletPage: return .bookletPage
        case .ignore: return .ignore
        }
    }

    var discNumber: Int {
        if case let .disc(number) = self { return number }
        return 1
    }
}

struct ArtworkSearchSheetView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

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
    @State private var caaImages: [CAABookletImage] = []
    @State private var artError: String? = nil

    // Image Selection state
    @State private var selectedImages: Set<String> = [] // imageURL string
    @State private var imageRoles: [String: ArtRoleChoice] = [:] // imageURL string to role choice
    @State private var isDownloading = false

    // Full-size preview shown over the grid (does not affect selection).
    @State private var previewImage: CAABookletImage? = nil

    // Result filtering / sorting / grouping (the release list).
    @State private var mediaFilter: String? = nil
    @State private var countryFilter: String? = nil
    @State private var sortByYear = false
    @State private var groupByRelease = false

    init(album: Album) {
        self.album = album
        _artistQuery = State(initialValue: album.artistName)
        _albumQuery = State(initialValue: album.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            
            if selectedReleaseID == nil {
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
        .frame(width: 680, height: 550)
        .background(theme.chassis)
        .onAppear {
            executeSearch()
        }
        .overlay {
            if isDownloading {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("IMPORTING ARTWORK...")
                            .font(CarbonFont.mono(10, weight: .bold))
                            .tracking(1.5)
                            .foregroundColor(.white)
                        Text("Optimizing images and updating audio tags")
                            .font(CarbonFont.sans(11, weight: .regular))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(24)
                    .background(theme.chassisDeep.opacity(0.9))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(radius: 12)
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if let preview = previewImage {
                imagePreviewOverlay(preview)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewImage?.id)
    }

    private func imagePreviewOverlay(_ img: CAABookletImage) -> some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { previewImage = nil }

            VStack(spacing: 12) {
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
                .frame(maxWidth: 460, maxHeight: 400)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.6), radius: 18, y: 8)

                if !img.comment.isEmpty {
                    Text(img.comment)
                        .font(CarbonFont.sans(11, weight: .regular))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                Button("Close") { previewImage = nil }
                    .buttonStyle(.bordered)
            }
            .padding(30)
        }
    }

    // Header
    private var header: some View {
        HStack {
            Text("Search Album Artwork".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
            
            if selectedReleaseID != nil {
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
                            .font(CarbonFont.mono(9, weight: .bold))
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
            VStack(alignment: .leading, spacing: 3) {
                Text("ARTIST")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(theme.ink3)
                TextField("Artist", text: $artistQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text("ALBUM")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(theme.ink3)
                TextField("Album", text: $albumQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
            }
            
            KeyButton(style: .selected, action: executeSearch) {
                Text("SEARCH")
                    .font(CarbonFont.mono(9.5, weight: .bold))
            }
            .frame(width: 80, height: 22)
        }
    }

    // Content
    @ViewBuilder
    private var contentArea: some View {
        if selectedReleaseID != nil {
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Searching MusicBrainz releases...")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
            } else if let error = searchError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.orange)
                    Text(error)
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                }
            } else if mbReleases.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 24))
                        .foregroundColor(theme.ink4)
                    Text("Enter search terms to find releases on MusicBrainz.")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
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
            toggleChip("SORT BY YEAR", isOn: sortByYear) { sortByYear.toggle() }
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
        .buttonStyle(.plain)
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
        if sortByYear {
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

    private func releaseRow(_ release: MBReleaseCandidate) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
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
            
            KeyButton(style: .normal, action: {
                loadReleaseArtwork(release)
            }) {
                Text("GET ARTWORK")
                    .font(CarbonFont.mono(8.5, weight: .bold))
            }
            .frame(width: 96, height: 22)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // Artwork grid section
    @ViewBuilder
    private var artworkGridSection: some View {
        ZStack {
            if loadingArt {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching artwork list from Cover Art Archive...")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
            } else if let error = artError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.orange)
                    Text(error)
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                }
            } else if caaImages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 24))
                        .foregroundColor(theme.ink4)
                    Text("No artwork scans found for this release.")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(selectedReleaseTitle.uppercased())
                            .font(CarbonFont.mono(9, weight: .bold))
                            .foregroundStyle(theme.ink3)
                        Spacer()
                        Text("\(caaImages.count) images available")
                            .font(CarbonFont.mono(8.5, weight: .semibold))
                            .foregroundStyle(theme.ink4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(theme.chassisHi.opacity(0.3))
                    .overlay(Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1), alignment: .bottom)
                    
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], spacing: 16) {
                            ForEach(caaImages) { img in
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

    private func artworkCell(_ img: CAABookletImage) -> some View {
        let isSelected = selectedImages.contains(img.id)
        return VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
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
                .shadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
                .onTapGesture {
                    toggleImageSelection(img)
                }

                Button(action: {
                    toggleImageSelection(img)
                }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? theme.orange : .white)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)

                // Expand-to-preview is a ZStack sibling (NOT inside the image's
                // .onTapGesture subtree, which otherwise steals the click and only
                // toggles selection). Positioned top-right to mirror the checkmark.
                Button(action: { previewImage = img }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .frame(width: 130, height: 130, alignment: .topTrailing)
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
                Text("Cover").tag(ArtRoleChoice.cover)
                Text("Back").tag(ArtRoleChoice.back)
                if album.discCount > 1 {
                    ForEach(1...album.discCount, id: \.self) { disc in
                        Text("Disc \(disc)").tag(ArtRoleChoice.disc(disc))
                    }
                } else {
                    Text("Disc/CD").tag(ArtRoleChoice.disc(1))
                }
                Text("Booklet Page").tag(ArtRoleChoice.bookletPage)
                Text("Ignore").tag(ArtRoleChoice.ignore)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(!isSelected)
        }
        .frame(width: 140)
    }

    private func defaultRole(for types: [String]) -> ArtRoleChoice {
        let typesLower = types.map { $0.lowercased() }
        if typesLower.contains("front") {
            return .cover
        } else if typesLower.contains("back") {
            return .back
        } else if typesLower.contains("medium") {
            return .disc(1)
        } else if typesLower.contains("booklet") || typesLower.contains("liner") || typesLower.contains("tray") || typesLower.contains("inlay") {
            return .bookletPage
        } else {
            return .bookletPage
        }
    }

    private func toggleImageSelection(_ img: CAABookletImage) {
        if selectedImages.contains(img.id) {
            selectedImages.remove(img.id)
        } else {
            selectedImages.insert(img.id)
            if imageRoles[img.id] == nil {
                imageRoles[img.id] = defaultRole(for: img.types)
            }
        }
    }

    // Footer
    private var footer: some View {
        HStack {
            Spacer()
            
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            
            if selectedReleaseID != nil {
                let downloads = compileDownloads()
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 10)
                } else {
                    KeyButton(style: downloads.isEmpty ? .disabled : .selected, action: executeDownload) {
                        Text("IMPORT \(downloads.count) IMAGES")
                            .font(CarbonFont.mono(9.5, weight: .bold))
                            .tracking(1.5)
                    }
                    .frame(width: 140, height: CarbonLayout.keyHeight)
                }
            }
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
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
        caaImages = []
        artError = nil
        selectedImages = []
        imageRoles = [:]
        
        Task {
            do {
                let images = try await model.remoteArtworkService.fetchCoverArtArchiveImages(
                    releaseMBID: release.id
                )
                await MainActor.run {
                    self.caaImages = images
                    self.loadingArt = false
                    if images.isEmpty {
                        self.artError = "No images are available in the Cover Art Archive for this release."
                    }
                }
            } catch {
                await MainActor.run {
                    self.loadingArt = false
                    self.artError = error.localizedDescription
                }
            }
        }
    }

    private func getSuggestedFilename(for image: CAABookletImage, index: Int, choice: ArtRoleChoice) -> String {
        let ext = image.imageURL.pathExtension.isEmpty ? "jpg" : image.imageURL.pathExtension.lowercased()
        switch choice {
        case .cover:
            return index == 0 ? "cover.\(ext)" : "cover_\(index + 1).\(ext)"
        case .back:
            return index == 0 ? "back.\(ext)" : "back_\(index + 1).\(ext)"
        case .disc:
            // Multi-disc albums get disc-numbered names (disc1.jpg, disc2.jpg);
            // single-disc albums keep the plain "disc" name.
            let base = album.discCount > 1 ? "disc\(choice.discNumber)" : "disc"
            return index == 0 ? "\(base).\(ext)" : "\(base)_\(index + 1).\(ext)"
        case .bookletPage:
            return String(format: "booklet_%02d.\(ext)", index + 1)
        case .ignore:
            return "ignored_\(index + 1).\(ext)"
        }
    }

    private func compileDownloads() -> [(url: URL, role: ArtworkRole, suggestedFilename: String)] {
        var downloads: [(url: URL, role: ArtworkRole, suggestedFilename: String)] = []
        var choiceCounts: [ArtRoleChoice: Int] = [:]

        let orderedSelected = caaImages.filter { selectedImages.contains($0.id) }

        for img in orderedSelected {
            let choice = imageRoles[img.id] ?? defaultRole(for: img.types)
            let count = choiceCounts[choice, default: 0]
            choiceCounts[choice] = count + 1

            let filename = getSuggestedFilename(for: img, index: count, choice: choice)
            downloads.append((url: img.imageURL, role: choice.role, suggestedFilename: filename))
        }
        return downloads
    }

    private func executeDownload() {
        let downloads = compileDownloads()
        guard !downloads.isEmpty else { return }
        
        isDownloading = true
        
        Task {
            await model.downloadAndImportArtwork(images: downloads, for: album)
            await MainActor.run {
                self.isDownloading = false
                dismiss()
            }
        }
    }
}
