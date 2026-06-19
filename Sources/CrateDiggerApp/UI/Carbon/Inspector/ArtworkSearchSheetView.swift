import SwiftUI
import CrateDiggerCore

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
    @State private var imageRoles: [String: ArtworkRole] = [:] // imageURL string to Role
    @State private var isDownloading = false

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
        HStack(spacing: 12) {
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
            
            VStack(spacing: 0) {
                Spacer()
                KeyButton(style: .selected, action: executeSearch) {
                    Text("SEARCH")
                        .font(CarbonFont.mono(9.5, weight: .bold))
                }
                .frame(width: 80, height: 22)
            }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mbReleases) { release in
                            releaseRow(release)
                            Divider().background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("Cover").tag(ArtworkRole.cover)
                Text("Back").tag(ArtworkRole.back)
                Text("Disc/CD").tag(ArtworkRole.disc)
                Text("Booklet Page").tag(ArtworkRole.bookletPage)
                Text("Ignore").tag(ArtworkRole.ignore)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(!isSelected)
        }
        .frame(width: 140)
    }

    private func defaultRole(for types: [String]) -> ArtworkRole {
        let typesLower = types.map { $0.lowercased() }
        if typesLower.contains("front") {
            return .cover
        } else if typesLower.contains("back") {
            return .back
        } else if typesLower.contains("medium") {
            return .disc
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

    private func getSuggestedFilename(for image: CAABookletImage, index: Int, role: ArtworkRole) -> String {
        let ext = image.imageURL.pathExtension.isEmpty ? "jpg" : image.imageURL.pathExtension.lowercased()
        switch role {
        case .cover:
            return index == 0 ? "cover.\(ext)" : "cover_\(index + 1).\(ext)"
        case .back:
            return index == 0 ? "back.\(ext)" : "back_\(index + 1).\(ext)"
        case .disc:
            return index == 0 ? "disc.\(ext)" : "disc_\(index + 1).\(ext)"
        case .bookletPage:
            return String(format: "booklet_%02d.\(ext)", index + 1)
        case .ignore:
            return "ignored_\(index + 1).\(ext)"
        case .auto:
            return "artwork_\(index + 1).\(ext)"
        }
    }

    private func compileDownloads() -> [(url: URL, role: ArtworkRole, suggestedFilename: String)] {
        var downloads: [(url: URL, role: ArtworkRole, suggestedFilename: String)] = []
        var roleCounts: [ArtworkRole: Int] = [:]
        
        let orderedSelected = caaImages.filter { selectedImages.contains($0.id) }
        
        for img in orderedSelected {
            let role = imageRoles[img.id] ?? defaultRole(for: img.types)
            let count = roleCounts[role, default: 0]
            roleCounts[role] = count + 1
            
            let filename = getSuggestedFilename(for: img, index: count, role: role)
            downloads.append((url: img.imageURL, role: role, suggestedFilename: filename))
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
