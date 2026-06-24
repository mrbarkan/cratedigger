import SwiftUI
import UniformTypeIdentifiers
import CrateDiggerCore

struct ArtworkInspectorView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album?
    
    @State private var manifest: ArtworkManifest = ArtworkManifest()
    @State private var imageURLs: [URL] = []
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var isSaving = false
    @State private var showingSearch = false
    
    private var mediaFormatLabel: String {
        switch manifest.mediaFormat {
        case .some(.cd):    return "CD"
        case .some(.vinyl): return "VINYL"
        default:            return "AUTO"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Self-contained media-format selector. Keeping the "FORMAT"
                // hint inside the pill means the label can never be clipped or
                // stranded from its value when the inspector is narrow.
                Menu {
                    Button("Auto") { manifest.mediaFormat = nil }
                    Button("CD") { manifest.mediaFormat = .cd }
                    Button("Vinyl") { manifest.mediaFormat = .vinyl }
                } label: {
                    HStack(spacing: 6) {
                        Text("FORMAT")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .foregroundColor(theme.ink3)
                        Text(mediaFormatLabel)
                            .font(CarbonFont.mono(9, weight: .bold))
                            .foregroundColor(theme.ink2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(theme.ink3)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(ChromeChassis(theme: theme, cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // Action buttons fill the remaining width evenly, matching the
                // "Library Tools" row pattern in InspectorPane.
                if canUploadArtwork {
                    KeyButton(style: .normal, action: uploadArtworkFromDisk) {
                        Text("ADD FILE…")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                }

                if album != nil {
                    KeyButton(style: .normal, action: { showingSearch = true }) {
                        Text("SEARCH ONLINE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                }

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    KeyButton(style: .selected, action: saveChanges) {
                        Text("SAVE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 14)], spacing: 14) {
                    ForEach(imageURLs, id: \.self) { url in
                        VStack(spacing: 6) {
                            if let nsImage = thumbnails[url] {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 100, height: 100)
                                    .clipped()
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1)
                                    )
                                    .cornerRadius(4)
                            } else {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 100, height: 100)
                                    .overlay(
                                        ProgressView().controlSize(.small)
                                    )
                                    .cornerRadius(4)
                            }
                            
                            let fileName = url.lastPathComponent
                            Picker("", selection: Binding(
                                get: { manifest.roles[fileName] ?? .auto },
                                set: { newValue in
                                    manifest.roles[fileName] = newValue
                                }
                            )) {
                                Text("Auto").tag(ArtworkRole.auto)
                                Text("Ignore").tag(ArtworkRole.ignore)
                                Text("Cover").tag(ArtworkRole.cover)
                                Text("Back").tag(ArtworkRole.back)
                                Text("Disc/Vinyl").tag(ArtworkRole.disc)
                                Text("Booklet Page").tag(ArtworkRole.bookletPage)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            
                            Text(fileName)
                                .font(CarbonFont.mono(8, weight: .regular))
                                .foregroundColor(theme.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(14)
            }
        }
        .onAppear {
            loadManifest()
        }
        .onChange(of: album) { _ in
            loadManifest()
        }
        .task(id: imageURLs) {
            var loaded: [URL: NSImage] = [:]
            for url in imageURLs {
                if let nsImage = await generateThumbnail(for: url) {
                    loaded[url] = nsImage
                }
            }
            self.thumbnails = loaded
        }
        .sheet(isPresented: $showingSearch, onDismiss: { loadManifest() }) {
            if let album = album {
                ArtworkSearchSheetView(album: album)
            }
        }
    }
    
    /// Manual upload only makes sense for albums backed by real files on disk.
    private var canUploadArtwork: Bool {
        album?.tracks.first?.track.fileURL.isFileURL ?? false
    }

    private func uploadArtworkFromDisk() {
        guard let album = album else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "Choose cover art"
        panel.message = "This image becomes the cover and is embedded into every track on the album."
        panel.prompt = "Use as Cover"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isSaving = true
        Task {
            await model.attachLocalArtwork(fileURLs: [url], role: .cover, for: album)
            await MainActor.run {
                isSaving = false
                loadManifest()
            }
        }
    }

    private func generateThumbnail(for url: URL) async -> NSImage? {
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        
        guard let cgImage = cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
    
    private func loadManifest() {
        guard let album = album, let representative = album.tracks.first?.track.fileURL else {
            imageURLs = []
            manifest = ArtworkManifest()
            return
        }
        
        let albumFolder = representative.deletingLastPathComponent()
        self.manifest = ArtworkManifest.load(from: albumFolder) ?? ArtworkManifest(mediaFormat: album.mediaFormat, roles: [:])
        
        var foundImages: [URL] = []
        let candidateDirNames = ["", "artwork", "Artwork", "scans", "Scans", "booklet", "Booklet", "covers", "Covers"]
        let fm = FileManager.default
        
        for dirName in candidateDirNames {
            let dir = dirName.isEmpty ? albumFolder : albumFolder.appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    let exts = ["jpg", "jpeg", "png", "webp", "gif"]
                    let images = contents.filter { exts.contains($0.pathExtension.lowercased()) }
                    foundImages.append(contentsOf: images)
                }
            }
        }
        
        self.imageURLs = Array(Set(foundImages)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    private func saveChanges() {
        guard let album = album, let representative = album.tracks.first?.track.fileURL else { return }
        isSaving = true
        
        Task {
            let albumFolder = representative.deletingLastPathComponent()
            
            // 1. Save the manifest
            try? manifest.save(to: albumFolder)
            
            // 2. Look for cover image and embed it into every track on the album.
            var embeddedCover = false
            if let coverFileName = manifest.roles.first(where: { $0.value == .cover })?.key {
                let coverURL = albumFolder.appendingPathComponent(coverFileName)
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    if let editor = model.metadataEditor {
                        for loadedTrack in album.tracks {
                            let fileURL = loadedTrack.track.fileURL
                            try? editor.embedArtwork(to: fileURL, imageURL: coverURL)
                        }
                        embeddedCover = true
                    }
                }
            }

            let trackCount = album.tracks.count
            await MainActor.run {
                isSaving = false
                model.refreshLibrary()
                if embeddedCover {
                    model.appAlert = .info(
                        title: "Cover art saved",
                        message: "Embedded into all \(trackCount) track\(trackCount == 1 ? "" : "s") of “\(album.title)”."
                    )
                } else {
                    model.appAlert = .info(
                        title: "Saved",
                        message: "Artwork roles saved for “\(album.title)”."
                    )
                }
            }
        }
    }
}
