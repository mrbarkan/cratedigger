import SwiftUI
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
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("MEDIA FORMAT")
                    .font(CarbonFont.mono(9, weight: .bold))
                    .foregroundColor(theme.ink3)
                Picker("", selection: $manifest.mediaFormat) {
                    Text("Auto").tag(MediaFormat?.none)
                    Text("CD").tag(MediaFormat?.some(.cd))
                    Text("Vinyl").tag(MediaFormat?.some(.vinyl))
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                
                Spacer()
                
                if album != nil {
                    KeyButton(style: .normal, action: { showingSearch = true }) {
                        Text("SEARCH ONLINE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(width: 92, height: 18)
                }
                
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    KeyButton(style: .selected, action: saveChanges) {
                        Text("SAVE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(width: 44, height: 18)
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
        .sheet(isPresented: $showingSearch) {
            if let album = album {
                ArtworkSearchSheetView(album: album)
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
            
            // 2. Look for cover image
            if let coverFileName = manifest.roles.first(where: { $0.value == .cover })?.key {
                let coverURL = albumFolder.appendingPathComponent(coverFileName)
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    if let editor = model.metadataEditor {
                        for loadedTrack in album.tracks {
                            let fileURL = loadedTrack.track.fileURL
                            try? editor.embedArtwork(to: fileURL, imageURL: coverURL)
                        }
                    }
                }
            }
            
            await MainActor.run {
                isSaving = false
                model.refreshLibrary()
            }
        }
    }
}
