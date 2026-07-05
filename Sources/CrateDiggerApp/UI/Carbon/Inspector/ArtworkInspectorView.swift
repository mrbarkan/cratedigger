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
    /// When on (default), the cover embedded into each track is downscaled to a
    /// 600px baseline JPEG so Rockbox / legacy players can read it. Off embeds the
    /// full-resolution original. Persisted so the choice sticks across sessions.
    @AppStorage("embedDeviceCompatibleArt") private var deviceCompatibleArt = true
    /// The Save button only glows (and is worth pressing) once the user has
    /// actually changed something — found new artwork, or edited a role/format.
    @State private var isDirty = false
    
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
                    Button("Auto") { manifest.mediaFormat = nil; isDirty = true }
                    Button("CD") { manifest.mediaFormat = .cd; isDirty = true }
                    Button("Vinyl") { manifest.mediaFormat = .vinyl; isDirty = true }
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
                    KeyButton(style: isDirty ? .selected : .normal, action: saveChanges) {
                        Text("SAVE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .disabled(!isDirty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Toggle(isOn: $deviceCompatibleArt) {
                    Text("Device-safe artwork (600px baseline JPEG)")
                        .font(CarbonFont.mono(9, weight: .bold))
                        .foregroundColor(theme.ink2)
                }
                .toggleStyle(.checkbox)
                .help("Embeds a downscaled baseline-JPEG cover so Rockbox and legacy players can read it. Turn off to embed the full-resolution original for modern/desktop players.")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

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
                                    isDirty = true
                                }
                            )) {
                                Text("Auto").tag(ArtworkRole.auto)
                                Text("Ignore").tag(ArtworkRole.ignore)
                                Text("Main Cover").tag(ArtworkRole.cover)
                                Text("Alt Cover").tag(ArtworkRole.altCover)
                                Text("Back").tag(ArtworkRole.back)
                                Text("Disc/Vinyl").tag(ArtworkRole.disc)
                                Text("Inlay / Insert").tag(ArtworkRole.inlay)
                                Text("Booklet Page").tag(ArtworkRole.bookletPage)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)

                            // For disc labels: the CD number (multi-disc sets) and/or
                            // vinyl side, so the spinning record shows the right one
                            // per the playing track's disc.
                            if (manifest.roles[fileName] ?? .auto) == .disc {
                                if (album?.discCount ?? 1) > 1 {
                                    TextField("CD #", text: Binding(
                                        get: { manifest.discNumbers?[fileName].map(String.init) ?? "" },
                                        set: { setDiscNumber(fileName, $0) }
                                    ))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.center)
                                    .font(CarbonFont.mono(8.5, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                                    .cornerRadius(4)
                                    .frame(maxWidth: .infinity)
                                }
                                TextField("Side (A/B…)", text: Binding(
                                    get: { manifest.discSides?[fileName] ?? "" },
                                    set: { setDiscSide(fileName, $0) }
                                ))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.center)
                                .font(CarbonFont.mono(8.5, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                                .cornerRadius(4)
                                .frame(maxWidth: .infinity)
                            }

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
        // Reload the folder scan on album switch. Keyed on album.id via .task(id:) —
        // the same trigger AlbumPoster uses and which reliably re-fires. A plain
        // .onChange(of: album) was missing switches here (Album's Equatable is
        // id-only), leaving the ART grid showing the previously-selected album's art.
        .task(id: album?.id) {
            loadManifest()
            isDirty = false
        }
        .task(id: imageURLs) {
            var loaded: [URL: NSImage] = [:]
            for url in imageURLs {
                if let nsImage = await loadThumbnail(url: url, maxPixelSize: 300) {
                    loaded[url] = nsImage
                }
            }
            self.thumbnails = loaded
        }
        .sheet(isPresented: $showingSearch, onDismiss: {
            let before = imageURLs.count
            loadManifest()
            if imageURLs.count > before { isDirty = true }   // new artwork found
        }) {
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
                isDirty = true   // a new cover was added
            }
        }
    }

    private func setDiscSide(_ fileName: String, _ raw: String) {
        let v = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sides = manifest.discSides ?? [:]
        if v.isEmpty { sides[fileName] = nil } else { sides[fileName] = v }
        manifest.discSides = sides.isEmpty ? nil : sides
        isDirty = true
    }

    private func setDiscNumber(_ fileName: String, _ raw: String) {
        var nums = manifest.discNumbers ?? [:]
        if let n = Int(raw.trimmingCharacters(in: .whitespaces)), n > 0 {
            nums[fileName] = n
        } else {
            nums[fileName] = nil
        }
        manifest.discNumbers = nums.isEmpty ? nil : nums
        isDirty = true
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
            
            await MainActor.run {
                isSaving = false
                isDirty = false
                model.refreshLibrary()
                // Embed a compatible 600px baseline copy of the cover into each
                // track in the BACKGROUND (keeping the full-res cover.jpg) — so the
                // art travels inside the files without blocking on the per-file
                // rewrite. The folder cover already drives in-app display.
                model.embedCoverIntoTracksInBackground(for: album, deviceCompatible: deviceCompatibleArt)
                model.appAlert = .info(
                    title: "Artwork saved",
                    message: "Saved for “\(album.title)”. Embedding the cover into your tracks in the background."
                )
            }
        }
    }
}
