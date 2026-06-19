import SwiftUI
import CryptoKit
import CrateDiggerCore

struct ArtworkGalleryView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    
    @State private var selectedArtworkAlbum: Album? = nil
    @State private var showingFullScreen = false
    @State private var searchAlbum: Album? = nil
    @State private var searchResults: [RemoteArtCandidate] = []
    @State private var searching = false

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 18)
    ]

    struct RemoteArtCandidate: Identifiable {
        let id = UUID()
        let url: URL
        let source: String
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(allAlbums) { album in
                            albumCoverCell(album)
                        }
                    }
                    .padding(18)
                }
            }

            if showingFullScreen, let album = selectedArtworkAlbum {
                fullScreenViewer(album)
                    .transition(.opacity)
            }

            if let album = searchAlbum {
                artworkSearchOverlay(album)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chassis)
    }

    private var header: some View {
        HStack {
            Text("Album Art Gallery".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
            Text("\(allAlbums.count) Albums")
                .font(CarbonFont.mono(9.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private var allAlbums: [Album] {
        model.index.artists.flatMap { $0.albums }
    }

    private func albumCoverCell(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: {
                    selectedArtworkAlbum = album
                    showingFullScreen = true
                }) {
                    GalleryAlbumCoverView(album: album, size: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)

                // Booklet Indicator Badge (Top Right of Cover)
                if album.booklet != nil {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Circle().fill(theme.orange))
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        .shadow(radius: 2)
                        .padding(6)
                        .frame(width: 120, height: 120, alignment: .topTrailing)
                        .help("Digital Booklet/Liner Notes Available")
                }

                // Fetch Art badge if artwork missing
                if album.artworkHash == nil {
                    Button(action: {
                        searchAlbum = album
                        searchArtworkOnline(for: album)
                    }) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(theme.orange)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Search Cover Art Online")
                }
            }

            Text(album.title)
                .font(CarbonFont.sans(10.5, weight: .bold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Text(album.artistName)
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .lineLimit(1)
        }
        .frame(width: 120)
    }

    private func thumbnail(for album: Album) -> NSImage? {
        guard let hash = album.artworkHash else { return nil }
        return model.artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: 240, height: 240))
    }

    // MARK: - Full Screen Viewer

    private func fullScreenViewer(_ album: Album) -> some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    showingFullScreen = false
                }

            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: { showingFullScreen = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
                
                Spacer()

                GalleryAlbumCoverView(album: album, size: 600, contentMode: .fit)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)

                VStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(CarbonFont.sans(20, weight: .black))
                            .foregroundColor(.white)
                        Text(album.artistName)
                            .font(CarbonFont.mono(12, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    if let booklet = album.booklet {
                        Button(action: {
                            showingFullScreen = false
                            BookletWindowManager.shared.showBooklet(
                                booklet,
                                albumTitle: album.title,
                                artistName: album.artistName,
                                theme: theme
                            )
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "book.fill")
                                    .font(.system(size: 12))
                                Text("OPEN BOOKLET")
                                    .font(CarbonFont.mono(11, weight: .bold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(theme.orange)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                            .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 40)
                
                Spacer()
            }
        }
    }

    // MARK: - Online Artwork Search

    private func artworkSearchOverlay(_ album: Album) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    searchAlbum = nil
                }

            VStack(spacing: 0) {
                HStack {
                    Text("Select Album Artwork".uppercased())
                        .font(CarbonFont.mono(11, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Button("Close") {
                        searchAlbum = nil
                    }
                }
                .padding(14)
                .background(theme.chassisHi)
                
                if searching {
                    VStack {
                        Spacer()
                        ProgressView("Searching online cover art...")
                        Spacer()
                    }
                    .frame(height: 260)
                } else if searchResults.isEmpty {
                    VStack {
                        Spacer()
                        Text("No matching covers found.")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(height: 260)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 16) {
                            ForEach(searchResults) { candidate in
                                Button(action: {
                                    downloadAndIngestArtwork(candidate.url, for: album)
                                }) {
                                    AsyncImage(url: candidate.url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 160, height: 160)
                                                .cornerRadius(4)
                                        default:
                                            ProgressView()
                                                .frame(width: 160, height: 160)
                                        }
                                    }
                                    .overlay(
                                        Text(candidate.source)
                                            .font(.system(size: 8))
                                            .foregroundColor(.white)
                                            .padding(3)
                                            .background(Color.black.opacity(0.6))
                                            .cornerRadius(3)
                                            .padding(4),
                                        alignment: .bottomLeading
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                    .frame(height: 200)
                }
            }
            .frame(width: 540)
            .background(theme.chassis)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.15), lineWidth: 1))
            .shadow(radius: 12)
        }
    }

    private func searchArtworkOnline(for album: Album) {
        searching = true
        searchResults = []
        
        let query = "\(album.artistName) \(album.title)"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&media=music&entity=album&limit=5") else {
            searching = false
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                struct ResultEnvelope: Decodable {
                    let results: [ResultHit]
                }
                struct ResultHit: Decodable {
                    let artworkUrl100: String?
                }
                let envelope = try JSONDecoder().decode(ResultEnvelope.self, from: data)
                let candidates = envelope.results.compactMap { hit -> RemoteArtCandidate? in
                    guard let urlStr = hit.artworkUrl100,
                          let highResStr = urlStr.replacingOccurrences(of: "100x100bb", with: "600x600bb") as String?,
                          let artURL = URL(string: highResStr) else {
                        return nil
                    }
                    return RemoteArtCandidate(url: artURL, source: "iTunes")
                }
                await MainActor.run {
                    self.searchResults = candidates
                    self.searching = false
                }
            } catch {
                await MainActor.run {
                    self.searching = false
                }
            }
        }
    }

    private func downloadAndIngestArtwork(_ url: URL, for album: Album) {
        searchAlbum = nil
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let nsImage = NSImage(data: data) else {
                return
            }

            let hash = SHA256Hex(data: data)
            let asset = ArtworkAsset(
                source: .remote,
                hash: hash,
                dimensions: ArtworkDimensions(width: Int(nsImage.size.width), height: Int(nsImage.size.height)),
                data: data
            )
            
            // Ingest to app's cache
            model.artworkService.ingest(asset)

            // Organize: Write cover.jpg next to the first track of this album on disk!
            if let firstTrack = album.tracks.first {
                let parentFolder = firstTrack.track.fileURL.deletingLastPathComponent()
                let targetURL = parentFolder.appendingPathComponent("cover.jpg")
                try? data.write(to: targetURL, options: .atomic)
            }

            // Update in UI view-model
            await MainActor.run {
                model.fetchRemoteArtwork(for: album) // Force re-resolution
            }
        }
    }

    private func SHA256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

struct GalleryAlbumCoverView: View {
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album
    let size: CGFloat
    var contentMode: ContentMode = .fill
    @State private var localImage: NSImage?

    var body: some View {
        ZStack {
            if let img = localImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let hash = album.artworkHash,
                      let img = model.artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: size * 2, height: size * 2)) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                GeneratedPoster(seed: album.id)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: album.booklet?.frontCoverURL) {
            guard let coverURL = album.booklet?.frontCoverURL else {
                localImage = nil
                return
            }
            localImage = await loadLocalThumbnail(from: coverURL, maxPixelSize: Int(size * 2))
        }
    }

    private func loadLocalThumbnail(from url: URL, maxPixelSize: Int) async -> NSImage? {
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        
        guard let cgImage = cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
