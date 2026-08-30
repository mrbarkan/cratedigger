import SwiftUI
import UniformTypeIdentifiers
import CrateDiggerCore
import CryptoKit

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
    /// Images fetched but not yet committed — they live in the staging folder
    /// until SAVE, so nothing reaches the album folder by accident.
    @State private var stagedURLs: [URL] = []
    /// Roles for the staged files plus the marks: which existing files are to
    /// be trashed, and whether the embedded picture is to go. Persisted beside
    /// the staged images, so a session survives switching away and back.
    @State private var staging = StagedArtworkInfo()
    @State private var confirmingStrip = false
    @State private var confirmingDiscard = false

    /// What a grid tile stands for. The embedded picture is a tile too — it is
    /// artwork this album carries, and until now the one piece you couldn't
    /// see or remove from here.
    private enum ArtTile: Hashable {
        case embedded
        case staged(URL)
        case existing(URL)
    }

    private var albumFolder: URL? {
        album?.tracks.first?.track.fileURL.deletingLastPathComponent()
    }

    /// A file's name relative to the album folder, so an image in `Scans/` is
    /// addressed distinctly from one of the same name at the top level.
    private func relativePath(_ url: URL) -> String {
        guard let folder = albumFolder else { return url.lastPathComponent }
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// The album's embedded cover, when its tracks carry one.
    private var hasEmbeddedArt: Bool {
        guard let album else { return false }
        return album.tracks.contains { $0.track.artworkSource == .embedded && $0.track.artworkHash != nil }
    }

    private var embeddedDimensions: ArtworkDimensions? {
        album?.tracks.compactMap(\.track.artworkDimensions).max { $0.longEdge < $1.longEdge }
    }

    private var pendingCount: Int {
        stagedURLs.count + staging.removals.count + (staging.stripEmbedded ? 1 : 0)
    }

    private var hasPending: Bool { pendingCount > 0 }

    /// SAVE is worth pressing when there is pending artwork *or* an edited
    /// role/format — both are written by the same commit.
    private var canSave: Bool { hasPending || isDirty }

    private func isMarked(_ url: URL) -> Bool { staging.removals.contains(relativePath(url)) }

    private var tiles: [ArtTile] {
        var all: [ArtTile] = []
        if hasEmbeddedArt { all.append(.embedded) }
        all.append(contentsOf: stagedURLs.map(ArtTile.staged))
        all.append(contentsOf: orderedImageURLs.map(ArtTile.existing))
        return all
    }

    /// Grid order: role first (Main Cover → … → Ignore), then filename via
    /// `localizedStandardCompare` so `booklet_2` precedes `booklet_10`.
    ///
    /// Kept separate from `imageURLs` on purpose: `imageURLs` keys the
    /// thumbnail-loading `.task(id:)`, so reordering it on every role change
    /// would reload every thumbnail in the grid.
    private var orderedImageURLs: [URL] {
        imageURLs.sorted { lhs, rhs in
            let lRole = manifest.roles[lhs.lastPathComponent] ?? .auto
            let rRole = manifest.roles[rhs.lastPathComponent] ?? .auto
            if lRole.sortOrder != rRole.sortOrder { return lRole.sortOrder < rRole.sortOrder }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
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
                    ForEach(MediaFormat.allCases, id: \.self) { format in
                        Button {
                            manifest.mediaFormat = format
                            isDirty = true
                        } label: {
                            Label(format.rawValue, systemImage: format.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("FORMAT")
                            .foregroundColor(theme.ink3)
                        // Fixed-width value slot: "AUTO" and every format glyph
                        // occupy the same space, so picking one never resizes
                        // the key and shoves ADD / SEARCH / SAVE sideways.
                        Group {
                            if let format = manifest.mediaFormat {
                                Image(systemName: format.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                            } else {
                                Text("AUTO")
                            }
                        }
                        .foregroundColor(theme.ink2)
                        .frame(width: 34)
                    }
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.2)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(KeyChrome())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                // Action buttons fill the remaining width evenly, matching the
                // "Library Tools" row pattern in InspectorPane.
                // Short single words so all three read at the same size in the
                // same width — the full sentence lives in the tooltip.
                // One key, one window: online candidates and your own scans
                // now share the same grid, the same role picker and the same
                // IMPORT. Two keys for two halves of the same job was the odd
                // part, not the search.
                if album != nil {
                    KeyButton(style: canUploadArtwork ? .normal : .disabled,
                              action: { showingSearch = true }) {
                        HStack(spacing: 5) {
                            Image(systemName: "photo.badge.magnifyingglass")
                                .font(.system(size: 11, weight: .semibold))
                            Text("FIND ART")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .carbonTip("Find artwork online, or add your own scans from disk")
                }

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    // The device-safe setting lives here rather than in a row of
                    // its own: it is a global preference whose only effect is on
                    // this button's background embed step, so it belongs with the
                    // action it modifies, not with the per-album art above.
                    Menu {
                        Toggle("Device-safe artwork (600px baseline JPEG)", isOn: $deviceCompatibleArt)
                    } label: {
                        Text(hasPending ? "SAVE \(pendingCount)" : "SAVE")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(canSave ? (hasPending ? theme.orange : theme.ink2) : theme.ink3)
                    } primaryAction: {
                        saveChanges()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    // SAVE keeps its indicator: it is the one key here that
                    // also carries a menu (the device-safe toggle).
                    .menuIndicator(.visible)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(KeyChrome())
                    .opacity(canSave ? 1 : 0.42)
                    .disabled(!canSave)
                    .help("Saves artwork roles and format, and embeds the cover into every track on the album. Device-safe artwork embeds a downscaled baseline JPEG so Rockbox and legacy players can read it.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))

            if hasPending { pendingBar }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 14)], spacing: 14) {
                    ForEach(tiles, id: \.self) { tile in
                        artworkTile(tile)
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
            loadStaging()
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
        // Artwork search is a browsing task — it wants room, and it wants to sit
        // next to the album it is filling in. The old sheet's onDismiss work
        // moves into the binding's setter, which is what a close writes to now.
        .carbonPanel(
            isPresented: Binding(
                get: { showingSearch },
                set: { presented in
                    showingSearch = presented
                    guard !presented else { return }
                    // Whatever the panel fetched is staged, not imported —
                    // pick it up so the grid can show it as pending.
                    loadStaging()
                }
            ),
            title: "Search Album Artwork",
            minSize: NSSize(width: 620, height: 460),
            initialSize: NSSize(width: 860, height: 660),
            maxSize: NSSize(width: 1400, height: 1000),
            autosaveName: "cratedigger.panel.artworkSearch"
        ) {
            if let album = album {
                ArtworkSearchSheetView(album: album).environmentObject(model)
            }
        }
        // Removing the picture from inside the audio files is the one action
        // here that can't be walked back, so it says how many files it will
        // rewrite before it's even staged.
        .confirmationDialog("Remove the embedded cover?",
                            isPresented: $confirmingStrip, titleVisibility: .visible) {
            Button("Mark \(album?.trackCount ?? 0) Track\((album?.trackCount ?? 0) == 1 ? "" : "s") for Removal", role: .destructive) {
                staging.stripEmbedded = true
                persistStaging()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saving will rewrite \(album?.trackCount ?? 0) file\((album?.trackCount ?? 0) == 1 ? "" : "s") to drop the picture from their tags. The audio is copied, not re-encoded, but the pictures can't be recovered.")
        }
        .confirmationDialog("Discard \(pendingCount) pending change\(pendingCount == 1 ? "" : "s")?",
                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discardPending() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Fetched images are thrown away and every mark is cleared. Nothing in the album folder has been changed yet.")
        }
        // Leaving with work pending isn't blocked — it's remembered. The staged
        // files and marks are on disk, so the warning points at something you
        // can still finish rather than reporting a loss.
        .onDisappear {
            guard hasPending, let album else { return }
            model.appAlert = .error(
                title: "Artwork still pending",
                message: "\(pendingCount) unsaved change\(pendingCount == 1 ? "" : "s") for “\(album.title)”. They're kept — reopen the ART tab and press SAVE, or DISCARD."
            )
        }
    }

    // MARK: - Pending session

    /// The one line that says the album folder has not been touched yet.
    private var pendingBar: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.orange).frame(width: 6, height: 6)
            Text("\(pendingCount) PENDING")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.orange)
            Text("nothing is written until you save")
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
            Spacer(minLength: 4)
            Button("DISCARD") { confirmingDiscard = true }
                .buttonStyle(.carbonHover)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.orange.opacity(0.08))
        .overlay(Rectangle().fill(theme.orange.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Tiles

    @ViewBuilder
    private func artworkTile(_ tile: ArtTile) -> some View {
        switch tile {
        case .embedded:          embeddedTile
        case .staged(let url):   fileTile(url, staged: true)
        case .existing(let url): fileTile(url, staged: false)
        }
    }

    /// The picture actually inside the audio files. It has no filename and no
    /// role to pick — it is either there or it isn't, so its only control is
    /// the one that takes it out.
    private var embeddedTile: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AlbumPoster(album: album)
                    .frame(width: 100, height: 100)
                    .opacity(staging.stripEmbedded ? 0.35 : 1)
                    .grayscale(staging.stripEmbedded ? 1 : 0)

                Button(action: {
                    if staging.stripEmbedded {
                        staging.stripEmbedded = false
                        persistStaging()
                    } else {
                        confirmingStrip = true
                    }
                }) {
                    Image(systemName: staging.stripEmbedded ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        // Without a content shape the target is the glyph's own
                        // strokes — a few thin diagonals — so a click a pixel
                        // off lands on the tile behind and appears to do
                        // nothing. The frame gives it a real 22pt disc.
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(2)
                .help(staging.stripEmbedded ? "Keep the embedded cover after all"
                                            : "Remove the cover embedded in the audio files")
            }
            .overlay(alignment: .bottomLeading) { tileBadge("IN FILES", tint: theme.cyan) }

            Text(staging.stripEmbedded ? "WILL BE REMOVED" : "Embedded in tracks")
                .font(CarbonFont.mono(8, weight: .bold))
                .foregroundColor(staging.stripEmbedded ? theme.orange : theme.ink3)
                .lineLimit(1)

            if let size = embeddedDimensions {
                Text("\(size.width)×\(size.height)")
                    .font(CarbonFont.mono(8))
                    .foregroundColor(theme.ink4)
            }
        }
    }

    private func fileTile(_ url: URL, staged: Bool) -> some View {
        let name = url.lastPathComponent
        let marked = !staged && isMarked(url)
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let nsImage = thumbnails[url] {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 100)
                            .clipped()
                    } else if url.pathExtension.lowercased() == "pdf" {
                        // No thumbnail path for a PDF, and a spinner that never
                        // resolves reads as broken rather than as "document".
                        Rectangle()
                            .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                            .frame(width: 100, height: 100)
                            .overlay(
                                VStack(spacing: 5) {
                                    Image(systemName: "doc.richtext")
                                        .font(.system(size: 24, weight: .light))
                                    Text("PDF")
                                        .font(CarbonFont.mono(8, weight: .bold))
                                        .tracking(1.2)
                                }
                                .foregroundStyle(theme.ink3)
                            )
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 100, height: 100)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(staged ? theme.orange.opacity(0.8)
                                       : (theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)),
                                lineWidth: staged ? 2 : 1)
                )
                .cornerRadius(4)
                .opacity(marked ? 0.35 : 1)
                .grayscale(marked ? 1 : 0)

                Button(action: { staged ? unstage(url) : toggleRemoval(url) }) {
                    Image(systemName: marked ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(2)
                .help(staged ? "Drop this from the pending import"
                             : (marked ? "Keep this file after all" : "Mark for the Trash — happens when you save"))
            }
            .overlay(alignment: .bottomLeading) {
                if staged { tileBadge("NEW", tint: theme.orange) }
            }

            Picker("", selection: roleBinding(for: url, staged: staged)) {
                ForEach(ArtworkRole.assignable, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
                Divider()
                Text("Auto").tag(ArtworkRole.auto)
                Text("Ignore").tag(ArtworkRole.ignore)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(marked)

            // For disc labels: the CD number (multi-disc sets) and/or vinyl
            // side, so the spinning record shows the right one per the playing
            // track's disc.
            if !staged, (manifest.roles[name] ?? .auto) == .disc {
                if (album?.discCount ?? 1) > 1 {
                    discField("CD #", text: Binding(
                        get: { manifest.discNumbers?[name].map(String.init) ?? "" },
                        set: { setDiscNumber(name, $0) }
                    ))
                }
                discField("Side (A/B…)", text: Binding(
                    get: { manifest.discSides?[name] ?? "" },
                    set: { setDiscSide(name, $0) }
                ))
            }

            Text(marked ? "WILL BE TRASHED" : name)
                .font(CarbonFont.mono(8, weight: marked ? .bold : .regular))
                .foregroundColor(marked ? theme.orange : theme.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func tileBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(CarbonFont.mono(7, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint))
            .padding(4)
    }

    private func discField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(CarbonFont.mono(8.5, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            .cornerRadius(4)
            .frame(maxWidth: .infinity)
    }

    private func roleBinding(for url: URL, staged: Bool) -> Binding<ArtworkRole> {
        let name = url.lastPathComponent
        return Binding(
            get: { staged ? (staging.roles[name] ?? .auto) : (manifest.roles[name] ?? .auto) },
            set: { newValue in
                if staged {
                    staging.roles[name] = newValue
                    persistStaging()
                } else {
                    manifest.roles[name] = newValue
                    isDirty = true
                }
            }
        )
    }

    // MARK: - Pending mutations

    private func persistStaging() {
        guard let folder = albumFolder else { return }
        if staging.isIdle && stagedURLs.isEmpty {
            ArtworkStaging.clear(forAlbumFolder: folder)
        } else {
            ArtworkStaging.saveInfo(staging, forAlbumFolder: folder)
        }
    }

    private func toggleRemoval(_ url: URL) {
        let path = relativePath(url)
        if let index = staging.removals.firstIndex(of: path) {
            staging.removals.remove(at: index)
        } else {
            staging.removals.append(path)
        }
        persistStaging()
    }

    /// Dropping a staged image deletes it from the cache, never the library —
    /// there is nothing to confirm because nothing of the user's is at risk.
    private func unstage(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        staging.roles[url.lastPathComponent] = nil
        staging.discNumbers[url.lastPathComponent] = nil
        loadStaging()
        persistStaging()
    }

    private func discardPending() {
        guard let folder = albumFolder else { return }
        ArtworkStaging.clear(forAlbumFolder: folder)
        staging = StagedArtworkInfo()
        stagedURLs = []
        loadManifest()
        isDirty = false
    }

    private func loadStaging() {
        guard let folder = albumFolder else {
            stagedURLs = []
            staging = StagedArtworkInfo()
            return
        }
        stagedURLs = ArtworkStaging.stagedFiles(forAlbumFolder: folder)
        staging = ArtworkStaging.info(forAlbumFolder: folder)
        // A mark for a file that has since gone is stale; drop it rather than
        // carrying a removal nothing can act on.
        let live = Set(imageURLs.map(relativePath))
        let pruned = staging.removals.filter(live.contains)
        if pruned.count != staging.removals.count {
            staging.removals = pruned
            persistStaging()
        }
    }

    /// Manual upload only makes sense for albums backed by real files on disk.    /// Manual upload only makes sense for albums backed by real files on disk.
    private var canUploadArtwork: Bool {
        album?.tracks.first?.track.fileURL.isFileURL ?? false
    }

    /// Flatten a panel selection into image files, walking any folders. Shallow
    /// per folder plus one level down, which covers the usual `Scans/` and
    /// `Scans/Booklet/` shapes without dragging in a whole music library if
    /// someone points this at one.
    static func expandToImageFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var seen = Set<String>()

        func addFile(_ url: URL) {
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { found.append(url) }
        }

        func addDirectory(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if depth > 0 { addDirectory(entry, depth: depth - 1) }
                } else {
                    addFile(entry)
                }
            }
        }

        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { addDirectory(url, depth: 1) } else { addFile(url) }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "gif", "bmp", "heic", "webp"]

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
                    // PDFs are listed too: one can arrive from the artwork
                    // search, and a file you cannot see is a file you cannot
                    // remove.
                    let exts = ["jpg", "jpeg", "png", "webp", "gif", "pdf"]
                    let images = contents.filter { exts.contains($0.pathExtension.lowercased()) }
                    foundImages.append(contentsOf: images)
                }
            }
        }
        
        self.imageURLs = Array(Set(foundImages)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    /// SAVE: the single point where anything reaches the album folder.
    ///
    /// The plan is worked out first (`ArtworkCommitPlanner`) so collisions and
    /// stale marks are resolved before a single file moves, and the order is
    /// fixed: trash, then write, then manifest, then the track rewrite. A
    /// failure at any step leaves the staging folder intact, so nothing is
    /// lost — you can press SAVE again.
    private func saveChanges() {
        guard let album, let folder = albumFolder else { return }

        let plan = ArtworkCommitPlanner.plan(
            existing: imageURLs.map(relativePath),
            staged: stagedURLs.map(\.lastPathComponent),
            removals: Set(staging.removals),
            stripEmbedded: staging.stripEmbedded
        )
        isSaving = true

        let stagingFolder = ArtworkStaging.folder(forAlbumFolder: folder)
        var updated = manifest
        if let releaseMBID = staging.releaseMBID { updated.releaseMBID = releaseMBID }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ArtworkManifest, Error> in
                var manifest = updated
                let fm = FileManager.default
                do {
                    // Trash first: a replacement cover can then take the name
                    // the old one just gave up.
                    for name in plan.trash {
                        let url = folder.appendingPathComponent(name)
                        guard fm.fileExists(atPath: url.path) else { continue }
                        try fm.trashItem(at: url, resultingItemURL: nil)
                        let leaf = URL(fileURLWithPath: name).lastPathComponent
                        manifest.roles[leaf] = nil
                        manifest.discSides?[leaf] = nil
                        manifest.discNumbers?[leaf] = nil
                    }

                    for write in plan.writes {
                        let from = stagingFolder.appendingPathComponent(write.stagedName)
                        let to = folder.appendingPathComponent(write.finalName)
                        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                        try fm.copyItem(at: from, to: to)
                        manifest.roles[write.finalName] = staging.roles[write.stagedName] ?? .auto
                        if let disc = staging.discNumbers[write.stagedName] {
                            var discs = manifest.discNumbers ?? [:]
                            discs[write.finalName] = disc
                            manifest.discNumbers = discs
                        }
                    }

                    if manifest.discSides?.isEmpty == true { manifest.discSides = nil }
                    if manifest.discNumbers?.isEmpty == true { manifest.discNumbers = nil }
                    try manifest.save(to: folder)
                    return .success(manifest)
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                isSaving = false
                switch outcome {
                case .failure(let error):
                    // A read-only or full volume used to report "Artwork saved"
                    // and silently drop the edit. Keep everything pending so
                    // the work isn't lost.
                    model.appAlert = .error(
                        title: "Couldn't save artwork",
                        message: "Writing to “\(folder.lastPathComponent)” failed: \(error.localizedDescription). Your pending changes are still here."
                    )
                    return

                case .success(let saved):
                    manifest = saved
                }

                // Committed: the staging folder has nothing left to hold.
                ArtworkStaging.clear(forAlbumFolder: folder)
                staging = StagedArtworkInfo()
                stagedURLs = []
                isDirty = false

                // This folder's contents just changed on disk. refreshLibrary()
                // rebuilds the indexes but reads per-folder booklet/mediaFormat
                // info from the disk cache, so without this the rebuild reuses
                // stale info for the folder we just edited.
                model.indexDiskCache.invalidate(
                    albumFolderPath: folder.path,
                    filePaths: album.tracks.map { $0.track.fileURL.path }
                )
                model.refreshLibrary()
                loadManifest()
                loadStaging()

                // Anything else showing this album's art re-reads the folder —
                // an open Artwork Viewer holds a page list built when it opened.
                NotificationCenter.default.post(
                    name: NSNotification.Name("CrateDiggerArtworkImported"), object: nil
                )

                if plan.stripEmbedded {
                    // Stripping and embedding in the same pass would fight over
                    // the same files; removal wins, since it's what was asked.
                    model.stripEmbeddedArtworkInBackground(for: album)
                } else {
                    // Embed a compatible 600px baseline copy of the cover into
                    // each track in the BACKGROUND (keeping the full-res
                    // cover.jpg) — so the art travels inside the files without
                    // blocking on the per-file rewrite.
                    model.embedCoverIntoTracksInBackground(for: album, deviceCompatible: deviceCompatibleArt)
                }

                model.appAlert = .info(
                    title: "Artwork saved",
                    message: summary(for: plan, album: album)
                )
            }
        }
    }

    private func summary(for plan: ArtworkCommitPlan, album: Album) -> String {
        var parts: [String] = []
        if !plan.writes.isEmpty { parts.append("\(plan.writes.count) image\(plan.writes.count == 1 ? "" : "s") added") }
        if !plan.trash.isEmpty { parts.append("\(plan.trash.count) moved to the Trash") }
        if plan.stripEmbedded {
            parts.append("removing the embedded cover from \(album.trackCount) track\(album.trackCount == 1 ? "" : "s") in the background")
        } else {
            parts.append("embedding the cover into your tracks in the background")
        }
        return "“\(album.title)”: " + parts.joined(separator: ", ") + "."
    }

}