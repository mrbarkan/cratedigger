import SwiftUI
import CryptoKit
import CrateDiggerCore

struct ArtworkGalleryView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    
    // When set, the browser pane shows the album page (cover + tracks) for this
    // album instead of the grid. Stored by id so it tracks index rebuilds (e.g.
    // after fetching artwork) rather than holding a stale Album snapshot.
    @State private var detailAlbumID: String? = nil
    /// Last album opened into the detail page — scrolled back into view when the
    /// grid re-appears, so returning doesn't jump to the top.
    @State private var lastOpenedID: String? = nil
    @Namespace private var artNamespace
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
            if let album = detailAlbum {
                albumDetailView(album)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    header

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(allAlbums) { album in
                                    albumCoverCell(album)
                                        .id(album.id)
                                }
                            }
                            .padding(18)
                        }
                        // Returning from the detail page: bring the opened album
                        // back into view instead of resetting to the top.
                        .onAppear {
                            if let id = lastOpenedID { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }

            if let album = searchAlbum {
                artworkSearchOverlay(album)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chassis)
    }

    /// Re-resolve the detail album from the live index each render so it
    /// reflects updates (e.g. artwork fetched while the page is open).
    private var detailAlbum: Album? {
        guard let id = detailAlbumID else { return nil }
        return model.index.album(id: id)
    }

    // Hero transition for the cover growing in/out of the detail page.
    private static let heroAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.82)

    private func openDetail(_ album: Album) {
        // Select the album so the Inspector (INFO/ART/DISC) follows it, and so
        // playTrack builds its queue from this album.
        model.selectedArtistID = album.artistID
        model.selectedAlbumID = album.id
        lastOpenedID = album.id
        withAnimation(Self.heroAnimation) { detailAlbumID = album.id }
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
                Button(action: { openDetail(album) }) {
                    GalleryAlbumCoverView(album: album, size: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
                        .matchedGeometryEffect(id: album.id, in: artNamespace)
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
                        .carbonTip("Digital Booklet/Liner Notes Available")
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
                    .carbonTip("Search Cover Art Online")
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
        .contextMenu { albumContextMenu(album) }
    }

    /// Right-click on a cover: the shared album actions plus the gallery's own
    /// artwork/booklet items.
    @ViewBuilder
    private func albumContextMenu(_ album: Album) -> some View {
        BrowserContextMenu.album(album, model: model)
        Divider()
        if album.artworkHash == nil {
            Button("Search Cover Art Online…") {
                searchAlbum = album
                searchArtworkOnline(for: album)
            }
        }
        if album.booklet != nil {
            Button("Open Booklet") { openBooklet(album) }
        }
    }

    // MARK: - Album Page (cover + tracks, in-pane, non-blocking)

    private func albumDetailView(_ album: Album) -> some View {
        VStack(spacing: 0) {
            detailHeader(album)

            GeometryReader { geo in
                let wide = geo.size.width > 620
                let coverSize = min(max(geo.size.width * (wide ? 0.34 : 0.6), 180), 320)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                coverBlock(album, size: coverSize)
                                metaBlock(album)
                                Spacer(minLength: 0)
                            }
                        } else {
                            coverBlock(album, size: coverSize)
                            metaBlock(album)
                        }

                        Rectangle().fill(theme.hair).frame(height: 1)
                            .padding(.vertical, 4)

                        trackList(album)
                    }
                    .padding(18)
                }
            }
        }
    }

    private func detailHeader(_ album: Album) -> some View {
        HStack {
            Button(action: { withAnimation(Self.heroAnimation) { detailAlbumID = nil } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text("Gallery".uppercased())
                        .font(CarbonFont.mono(10, weight: .bold))
                        .tracking(1.5)
                }
                .foregroundStyle(theme.ink2)
            }
            .buttonStyle(.plain)
            .carbonTip("Back to gallery")

            Spacer()

            Text("\(album.tracks.count) \(album.tracks.count == 1 ? "TRACK" : "TRACKS")")
                .font(CarbonFont.mono(9.5, weight: .semibold))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func coverBlock(_ album: Album, size: CGFloat) -> some View {
        let cover = GalleryAlbumCoverView(album: album, size: size, contentMode: .fit)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .matchedGeometryEffect(id: album.id, in: artNamespace)

        if album.booklet != nil {
            Button(action: { openBooklet(album) }) { cover }
                .buttonStyle(.plain)
                .carbonTip("Open booklet")
        } else {
            cover
        }
    }

    private func metaBlock(_ album: Album) -> some View {
        let specs = [album.year.map(String.init), album.tracks.first?.track.formatName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 8) {
            Text(album.title)
                .font(CarbonFont.sans(18, weight: .black))
                .foregroundStyle(theme.ink)
                .lineLimit(3)
            Text(album.artistName)
                .font(CarbonFont.mono(11, weight: .bold))
                .foregroundStyle(theme.ink2)
            if !specs.isEmpty {
                Text(specs.joined(separator: " · "))
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }

            HStack(spacing: 10) {
                if album.booklet != nil {
                    actionButton("OPEN BOOKLET", systemImage: "book.fill", filled: true) {
                        openBooklet(album)
                    }
                }
                if album.artworkHash == nil {
                    actionButton("SEARCH ART", systemImage: "magnifyingglass", filled: false) {
                        searchAlbum = album
                        searchArtworkOnline(for: album)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func actionButton(_ title: String, systemImage: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(CarbonFont.mono(10, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(filled ? theme.orange : theme.chassisHi)
            .foregroundColor(filled ? .white : theme.ink2)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(filled ? 0 : 0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(filled ? 0.2 : 0), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func trackList(_ album: Album) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(album.tracks.enumerated()), id: \.element.track.id) { index, loaded in
                trackRow(loaded, number: index + 1)
            }
        }
    }

    private func trackRow(_ loaded: LoadedTrack, number: Int) -> some View {
        let isNowPlaying = model.nowPlayingTrack?.track.id == loaded.track.id
        return Button(action: { model.playTrack(id: loaded.track.id) }) {
            HStack(spacing: 12) {
                Text(isNowPlaying ? "▸" : "\(number)")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .foregroundStyle(isNowPlaying ? theme.orange : theme.ink3)
                    .frame(width: 20, alignment: .trailing)
                Text(loaded.track.title)
                    .font(CarbonFont.sans(11.5, weight: isNowPlaying ? .bold : .regular))
                    .foregroundStyle(isNowPlaying ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer()
                Text(formatDuration(loaded.track.durationSeconds))
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isNowPlaying ? theme.orange.opacity(0.12) : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .carbonTip("Play \(loaded.track.title)")
        .contextMenu { BrowserContextMenu.track(loaded, model: model) }
    }

    private func openBooklet(_ album: Album) {
        guard let booklet = album.booklet else { return }
        BookletWindowManager.shared.showBooklet(
            booklet,
            albumTitle: album.title,
            artistName: album.artistName,
            theme: theme
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        return seconds.asClock
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
            } else {
                GeneratedPoster(seed: album.id)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: loadKey) { await loadCover() }
    }

    // Reload when the source art or requested size changes.
    private var loadKey: String {
        "\(album.booklet?.frontCoverURL?.path ?? album.artworkHash ?? album.id)-\(Int(size))"
    }

    /// All decoding happens off the main thread (folder cover via ImageIO,
    /// embedded art via ArtworkService.thumbnailAsync) so the grid scrolls smoothly.
    private func loadCover() async {
        let maxPixel = Int(size * 2)
        if let coverURL = album.booklet?.frontCoverURL {
            localImage = await loadThumbnail(url: coverURL, maxPixelSize: maxPixel)
        } else if let hash = album.artworkHash {
            localImage = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: maxPixel)
        } else {
            localImage = nil
        }
    }
}
