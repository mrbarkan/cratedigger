import AppKit
import CrateDiggerCore
import ImageIO
import SwiftUI

/// The Artist Pictures sheet: a grid of a device's artists, most tracks
/// first, each with the picture the player shows or would get (the artist's
/// default photo, the same one the artist page shows), where it came from,
/// and, for an uncertain match, the candidates to pick from. Per artist:
/// Accept a candidate, Choose File…, Don't Send to iPod, Clear. Find Missing
/// looks pictures up (library, Deezer, Commons) only when pressed; Apply
/// saves the owner's picks into the artist profiles and, when the device may
/// take them, writes them through the door. What each row says is Core's
/// (`ArtistPictureRow`); this draws it and keeps every image decode off the
/// main thread.
final class ArtistPicturesSheetController: ThemedSheetHostingController {
    private let sheet: ArtistPicturesSheetModel
    private let maxGridHeight: CGFloat

    init(sheet: ArtistPicturesSheetModel, maxGridHeight: CGFloat) {
        self.sheet = sheet
        self.maxGridHeight = maxGridHeight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        setThemedRoot(ArtistPicturesSheetView(sheet: sheet, maxGridHeight: maxGridHeight) { [weak self] in
            self?.dismiss(nil)
        })
    }

    /// Closing the sheet stops a Find Missing run; what it found so far is kept.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        sheet.cancelFind()
    }

    /// Presents the sheet for `profileID` on `host`'s window.
    @MainActor
    static func present(profileID: UUID, library: LibraryViewModel, from host: NSViewController) {
        let sheet = ArtistPicturesSheetModel(profileID: profileID, library: library)
        host.presentAsSheet(ArtistPicturesSheetController(
            sheet: sheet, maxGridHeight: DeviceReviewSheetController.maxListHeight(for: host.view.window)))
        sheet.load()
    }
}

// MARK: - Sheet state

@MainActor
final class ArtistPicturesSheetModel: ObservableObject {
    static let tooSmall = "That image is too small or the wrong shape. Use one at least 300 pixels on its short side."

    @Published private(set) var deviceName = ""
    @Published private(set) var isMounted = false
    @Published private(set) var rows: [ArtistPictureRow] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isFinding = false
    @Published private(set) var isApplying = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published var footer: String?
    @Published private(set) var edits: [String: ArtistPictureEdit] = [:]
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var candidateThumbnails: [URL: NSImage] = [:]
    /// Bumped whenever the thumbnails are dropped (after Apply or a removal),
    /// so every cell's `.task` loads its picture again even when its row did
    /// not change.
    @Published private(set) var thumbnailGeneration = 0
    /// Row id -> device path of the DEVICE rows whose picture CrateDigger
    /// wrote (journal-proven for that person): the only ones Remove from iPod acts on.
    @Published private(set) var crateDiggerPictures: [String: String] = [:]
    /// Asked before Apply writes every ready picture (check M5 passed).
    @Published var pendingConfirmation: (title: String, message: String)?

    /// A made-up sheet (the DEBUG hook): no device, no network, nothing written.
    let isPreview: Bool
    private let profileID: UUID?
    private weak var library: LibraryViewModel?
    private var artists: [ArtistOnDevice] = []
    private var tree = DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:], foldersWithAudio: [],
                                     artistsByFolder: [:])
    private var uncertain: [String: [ArtistPictureCandidate]] = [:]
    private var deviceRoot: URL?
    /// The DEBUG preview's own made-up profiles. A real sheet holds no
    /// store: it asks for the current one on each action, so a library
    /// moved or a drive unplugged while it is open is never read stale.
    private var previewStore: ArtistProfileStore?
    private var findTask: Task<Void, Never>?
    private let fetcher: URLSessionPictureFetcher
    /// The names the owner gave a picture in this sheet session, in the
    /// order they did: before check M5, Apply writes the first of these.
    private var changedNames: [String] = []
    /// Rows the owner asked to look up again despite a fresh "not found".
    private var lookAgain: Set<String> = []

    init(profileID: UUID, library: LibraryViewModel) {
        self.profileID = profileID
        self.library = library
        fetcher = library.artistPictureFetcher
        isPreview = false
    }

    private init(preview store: ArtistProfileStore, artists: [ArtistOnDevice], tree: DeviceArtTree,
                 uncertain: [String: [ArtistPictureCandidate]]) {
        profileID = nil
        isPreview = true
        fetcher = URLSessionPictureFetcher()
        previewStore = store
        self.artists = artists
        self.tree = tree
        self.uncertain = uncertain
        deviceName = "IPOD"
        isMounted = false
    }

    var counts: String {
        let byState = Dictionary(grouping: rows, by: \.state).mapValues(\.count)
        let parts: [(ArtistPictureRow.State, String)] = [(.onDevice, "on the iPod"), (.ready, "ready"),
                                                         (.check, "to check"), (.none, "without one"),
                                                         (.rejected, "not sent"), (.unnameable, "unnameable")]
        return parts.compactMap { state, label in byState[state].map { "\($0) \(label)" } }.joined(separator: " · ")
    }

    var canApply: Bool {
        !isPreview && !isApplying && !isFinding && (!edits.isEmpty || ArtistPictureRow.canApply(rows))
    }

    var canFind: Bool {
        !isPreview && !isFinding && !isApplying && !ArtistPictureRow.findTargets(rows, lookAgain: lookAgain).isEmpty
    }

    // MARK: Loading

    func load() {
        guard let library, let profileID else {
            Task { await recompute() }
            return
        }
        isLoading = true
        Task {
            guard let context = await library.artistPicturesContext(profileID: profileID) else {
                isLoading = false
                footer = "This device profile is gone."
                return
            }
            deviceName = context.device?.name ?? context.profile.name
            isMounted = context.device != nil
            deviceRoot = context.device?.volumeURL
            artists = context.artists
            tree = context.tree
            crateDiggerPictures = context.crateDiggerPictures
            await recompute()
            if artists.isEmpty {
                footer = isMounted ? "No artists on \(deviceName) yet." : "Connect \(deviceName) once so CrateDigger knows its artists."
            }
        }
    }

    /// Rows from Core, worked out off the main actor (it reads the profiles
    /// and checks photo files).
    private func recompute() async {
        guard let store = await currentStore() else {
            isLoading = false
            return
        }
        let artists = artists, tree = tree, uncertain = uncertain, edits = edits
        rows = await Task.detached(priority: .userInitiated) {
            ArtistPictureRow.rows(artists: artists, tree: tree, profiles: store, uncertain: uncertain, edits: edits)
        }.value
        isLoading = false
    }

    /// The profile store as it is now: the library's current one, or the preview's.
    private func currentStore() async -> ArtistProfileStore? {
        if isPreview { return previewStore }
        return await library?.currentArtistProfileStore()
    }

    // MARK: Images

    func loadThumbnail(for row: ArtistPictureRow) async {
        let key = row.id
        let data: Data?
        if isPreview {
            thumbnails[key] = thumbnails[key] ?? Self.placeholderImage(for: row.name)
            return
        }
        if case let .picked(prepared, _, _, _)? = edits[key] {
            data = prepared
        } else {
            let store = await currentStore(), photoHash = row.photoHash, devicePath = row.devicePath
            let root = deviceRoot
            let state = row.state
            data = await Task.detached(priority: .utility) { () -> Data? in
                switch state {
                case .ready:
                    return photoHash.flatMap { store?.photoData(hash: $0) }
                case .onDevice:
                    guard let root, let devicePath else { return nil }
                    return Self.readSmallFile(root.appendingPathComponent(devicePath))
                case .check, .none, .rejected, .unnameable:
                    return nil
                }
            }.value
        }
        guard let data else {
            thumbnails[key] = nil
            return
        }
        let image = await Task.detached(priority: .utility) { Self.thumbnail(data) }.value
        thumbnails[key] = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    func loadCandidateThumbnail(_ candidate: ArtistPictureCandidate) async {
        let url = candidate.imageURL
        guard candidateThumbnails[url] == nil else { return }
        if isPreview {
            candidateThumbnails[url] = Self.placeholderImage(for: candidate.name + candidate.sourceID)
            return
        }
        let fetcher = fetcher
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? await fetcher.data(from: url) else { return nil }
            return Self.thumbnail(data)
        }.value
        if let image { candidateThumbnails[url] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
    }

    nonisolated static func thumbnail(_ data: Data, side: Int = 280) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A plain file no larger than a source image may be, read; else nil.
    nonisolated static func readSmallFile(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= ArtistPictureImage.maximumSourceBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Per-artist actions

    func accept(_ candidate: ArtistPictureCandidate, for row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        let fetcher = fetcher
        Task {
            footer = "Getting the picture for \(row.name)…"
            let downloaded = await Task.detached(priority: .userInitiated) { () -> (original: Data, prepared: Data?)? in
                guard let data = try? await fetcher.data(from: candidate.imageURL) else { return nil }
                return (data, ArtistPictureImage.prepare(data))
            }.value
            switch downloaded {
            case nil:
                footer = "The picture for \(row.name) could not be downloaded."
            case (_, nil)?:
                footer = Self.tooSmall
            case let (original, bytes?)?:
                footer = nil
                await pick(bytes, original: original, source: candidate.source, candidate: candidate, for: row)
            }
        }
    }

    func chooseFile(for row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "Choose a picture of \(row.name)"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let chosen = await Task.detached(priority: .userInitiated) { () -> (original: Data, prepared: Data)? in
                guard let data = try? LibraryViewModel.readArtistPhotoFile(url),
                      let prepared = ArtistPictureImage.prepare(data) else { return nil }
                return (data, prepared)
            }.value
            guard let chosen else {
                footer = Self.tooSmall
                return
            }
            footer = nil
            await pick(chosen.prepared, original: chosen.original, source: .userFile, candidate: nil, for: row)
        }
    }

    private func pick(_ prepared: Data, original: Data, source: ArtistPictureSourceID,
                      candidate: ArtistPictureCandidate?, for row: ArtistPictureRow) async {
        edits[row.id] = .picked(prepared: prepared, original: original, source: source, candidate: candidate)
        changedNames.removeAll { $0 == row.name }
        changedNames.append(row.name)
        thumbnails[row.id] = await Task.detached(priority: .utility) { Self.thumbnail(prepared) }.value
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        await recompute()
    }

    func noPicture(for row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        // Never on a DEVICE row: nothing here covers a picture already on the iPod.
        guard row.state != .onDevice else { return }
        edits[row.id] = .noPicture
        changedNames.removeAll { $0 == row.name }
        thumbnails[row.id] = nil
        Task { await recompute() }
    }

    func clear(_ row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        edits[row.id] = .clear
        changedNames.removeAll { $0 == row.name }
        thumbnails[row.id] = nil
        Task { await recompute() }
    }

    private func previewOnly() {
        footer = "Preview: nothing is fetched or written."
    }

    // MARK: Find Missing and Apply

    /// Find Missing: every row to check or without a picture, except those
    /// a lookup found nothing for in the last 30 days (`findTargets`).
    func find() {
        guard canFind else { return }
        find(ArtistPictureRow.findTargets(rows, lookAgain: lookAgain))
    }

    /// Look Again, on a row with a fresh "not found": that artist, now.
    func lookAgain(_ row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        guard !isFinding, !isApplying else { return }
        lookAgain.insert(row.id)
        find([row])
    }

    private func find(_ wantedRows: [ArtistPictureRow]) {
        guard let library else { return }
        let wanted = Set(wantedRows.map(\.id))
        let targets = artists.filter { wanted.contains($0.foldedKey.isEmpty ? $0.name : $0.foldedKey) }
        guard !targets.isEmpty else { return }
        isFinding = true
        progress = (0, targets.count)
        footer = nil
        findTask = Task {
            let result = await library.findArtistPicturesForSheet(targets) { [weak self] done, total in
                self?.progress = (done, total)
            }
            guard let findings = result else {
                isFinding = false
                findTask = nil
                footer = "The library is disconnected, so nothing was looked up."
                return
            }
            var found = 0, toCheck = 0, none = 0, failed = 0
            for finding in findings {
                let key = PodBoxArtName.folded(finding.name)
                switch finding.outcome {
                case .found: found += 1
                case .uncertain(let candidates):
                    toCheck += 1
                    uncertain[key] = candidates
                case .notFound: none += 1
                case .failed: failed += 1
                }
                lookAgain.remove(key)
            }
            isFinding = false
            findTask = nil
            await recompute()
            var parts = ["Found \(found)", "\(toCheck) to check", "\(none) not found"]
            if failed > 0 { parts.append("\(failed) could not be looked up") }
            let unreached = targets.count - findings.count
            if unreached > 0 { parts.append("\(unreached) not reached") }
            footer = parts.joined(separator: ", ") + "."
        }
    }

    func cancelFind() {
        findTask?.cancel()
    }

    func apply() {
        guard canApply, let library, let profileID else { return }
        isApplying = true
        let names = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let edits = edits
        let changed = changedNames
        Task {
            let step = await library.applyArtistPictureEdits(edits, names: names, profileID: profileID,
                                                             changedNames: changed)
            self.edits = [:]
            switch step {
            case .finished(let line):
                footer = line
                isApplying = false
                await reloadFromDevice()
            case let .confirm(title, message):
                footer = "Pictures are saved."
                await recompute()
                // Still applying: the buttons stay off until the owner answers.
                pendingConfirmation = (title, message)
            }
        }
    }

    /// The owner's answer to `pendingConfirmation`.
    func answerConfirmation(write: Bool) {
        pendingConfirmation = nil
        guard write, let library, let profileID else {
            footer = "Pictures are saved. Nothing was written to the iPod."
            isApplying = false
            return
        }
        let changed = changedNames
        Task {
            footer = await library.writeArtistPicturesFromSheet(profileID: profileID, changedNames: changed)
            isApplying = false
            await reloadFromDevice()
        }
    }

    /// Remove from iPod, on a DEVICE row whose picture CrateDigger wrote.
    func removeFromIPod(_ row: ArtistPictureRow) {
        guard !isPreview else { return previewOnly() }
        guard let library, let profileID, let path = crateDiggerPictures[row.id], !isApplying, !isFinding else { return }
        isApplying = true
        Task {
            footer = await library.removeArtistPicture(profileID: profileID, name: row.name, path: path)
            isApplying = false
            await reloadFromDevice()
        }
    }

    /// What the device and the store hold now, with every thumbnail loaded
    /// again (a row whose state did not change would otherwise keep none).
    private func reloadFromDevice() async {
        if let library, let profileID, let context = await library.artistPicturesContext(profileID: profileID) {
            tree = context.tree
            artists = context.artists
            crateDiggerPictures = context.crateDiggerPictures
        }
        thumbnails = [:]
        thumbnailGeneration += 1
        await recompute()
    }

    // MARK: Preview

    /// A tile drawn from the name: a hue of its own and its initials. Small,
    /// made once per name.
    static func placeholderImage(for name: String, side: CGFloat = 140) -> NSImage {
        let hue = CGFloat(abs(name.hashValue % 360)) / 360
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(starting: NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1),
                   ending: NSColor(hue: hue, saturation: 0.6, brightness: 0.25, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -70)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let text = NSAttributedString(string: initials.isEmpty ? "?" : initials, attributes: [
            .font: NSFont.systemFont(ofSize: side * 0.31, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        image.unlockFocus()
        return image
    }

    #if DEBUG
    /// `CRATEDIGGER_ARTIST_PICTURES=1`: twelve made-up artists, one or more
    /// in every state, from artist profiles in a temporary folder. No device,
    /// no network, nothing written outside that folder.
    static func debugSample() -> ArtistPicturesSheetModel {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateDiggerArtistPicturesPreview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ArtistProfileStore(indexDirectory: folder)
        func artist(_ name: String, _ tracks: Int, folder: String? = nil) -> ArtistOnDevice {
            ArtistOnDevice(name: name, albumFolders: ["Music/\(folder ?? name)/2001 Album"], trackCount: tracks)
        }
        let artists = [
            artist("Radiohead", 112), artist("Björk", 97), artist("Massive Attack", 64), artist("Portishead", 51),
            artist("Caetano Veloso", 48), artist("Arvo Pärt", 40), artist("Air", 33), artist("Boards of Canada", 29),
            artist("Gal Costa", 24), artist("Stereolab", 19), artist("Mogwai", 12), artist("!!!", 7, folder: "Chk"),
        ]
        let tree = DeviceArtTree(peopleFiles: ["Radiohead.jpg"], coverFiles: [],
                                 folderImages: ["Music/Björk": ["folder.jpg"]], foldersWithAudio: [],
                                 artistsByFolder: [:])
        let found: [(String, ArtistPhoto.Source, Bool, ArtistPictureCredit?)] = [
            ("Massive Attack", .deezer, false, nil),
            ("Portishead", .commons, false,
             ArtistPictureCredit(fileName: "Portishead live 2013.jpg", licence: "CC BY-SA 3.0", author: "A. Photographer")),
            ("Caetano Veloso", .library, false, nil),
            ("Arvo Pärt", .owner, true, nil),
        ]
        for (name, source, picked, credit) in found {
            guard let photo = try? store.addPhoto(name: name, data: placeholderJPEG(for: name), source: source,
                                                  sourceID: source == .owner ? nil : name, credit: credit)
            else { continue }
            if picked { store.setDefault(name: name, hash: photo.hash) }
        }
        store.update(name: "Mogwai") { $0.notOnIPod = true }
        func candidate(_ name: String, _ source: ArtistPictureSourceID, _ id: String,
                       credit: ArtistPictureCredit? = nil) -> ArtistPictureCandidate {
            ArtistPictureCandidate(name: name, source: source, sourceID: id,
                                   imageURL: URL(string: "https://upload.wikimedia.org/preview/\(id).jpg")!, credit: credit)
        }
        let uncertain = [
            "air": [candidate("Air", .deezer, "d1"), candidate("AIR", .deezer, "d2"),
                    candidate("Air", .commons, "c1",
                              credit: ArtistPictureCredit(fileName: "Air (band) 2007.jpg", licence: "CC BY 2.0",
                                                          author: "Someone on Flickr"))],
            "boardsofcanada": [candidate("Boards of Canada", .deezer, "d3")],
        ]
        return ArtistPicturesSheetModel(preview: store, artists: artists, tree: tree, uncertain: uncertain)
    }

    /// A 320 px JPEG drawn from the name: large enough for the iPod's
    /// preparer, so the preview's profiles read as ready.
    private static func placeholderJPEG(for name: String) -> Data {
        guard let tiff = placeholderImage(for: name, side: 320).tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else { return Data([0xFF, 0xD8]) }
        return jpeg
    }
    #endif
}

// MARK: - SwiftUI body

private struct ArtistPicturesSheetView: View {
    @Environment(\.carbon) private var theme
    @ObservedObject var sheet: ArtistPicturesSheetModel
    let maxGridHeight: CGFloat
    let onClose: () -> Void

    private static let sheetWidth: CGFloat = 880
    private static let tile: CGFloat = 150
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            grid
                .padding(.bottom, 12)
            Divider()
                .padding(.bottom, 14)
            actionBar
        }
        .padding(20)
        .frame(width: Self.sheetWidth)
        .background(theme.chassis)
        .alert(sheet.pendingConfirmation?.title ?? "",
               isPresented: Binding(get: { sheet.pendingConfirmation != nil },
                                    set: { if !$0, sheet.pendingConfirmation != nil { sheet.answerConfirmation(write: false) } }),
               presenting: sheet.pendingConfirmation.map(\.message)) { _ in
            Button("Cancel", role: .cancel) { sheet.answerConfirmation(write: false) }
            Button("Write") { sheet.answerConfirmation(write: true) }
        } message: { message in
            Text(message)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artist Pictures")
                .font(CarbonFont.sans(22, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(subtitle)
                .font(CarbonFont.sans(13))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !sheet.rows.isEmpty {
                HStack(spacing: 8) {
                    Text(sheet.deviceName.uppercased())
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(theme.ink3)
                    Text(sheet.counts)
                        .font(CarbonFont.mono(11))
                        .foregroundStyle(theme.ink2)
                }
                .padding(.top, 2)
            }
        }
    }

    private var subtitle: String {
        let place = sheet.isMounted ? "the iPod" : "\(sheet.deviceName) when it is connected"
        return "The picture PodBox shows for each artist, which is the artist's default photo in CrateDigger. "
            + "CrateDigger never covers one already on the iPod. Pick one, or choose Don't Send to iPod, and "
            + "Apply saves your choices and writes them to \(place)."
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        if sheet.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading \(sheet.deviceName.isEmpty ? "the device" : sheet.deviceName)…")
                    .font(CarbonFont.mono(11))
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else if sheet.rows.isEmpty {
            Text("No artists to show.")
                .font(CarbonFont.mono(11))
                .foregroundStyle(theme.ink3)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(sheet.rows) { row in
                        ArtistPictureCell(row: row, sheet: sheet, tile: Self.tile)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: maxGridHeight)
        }
    }

    // MARK: Buttons

    private var actionBar: some View {
        HStack(spacing: 12) {
            if sheet.isFinding {
                ProgressView(value: Double(sheet.progress.done), total: Double(max(sheet.progress.total, 1)))
                    .frame(width: 120)
                Text("Looking up \(sheet.progress.done) of \(sheet.progress.total)…")
                    .font(CarbonFont.mono(10.5))
                    .foregroundStyle(theme.ink3)
                Button("Cancel") { sheet.cancelFind() }
            } else {
                Text(sheet.footer ?? defaultFooter)
                    .font(CarbonFont.mono(10.5))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Find Missing") { sheet.find() }
                .disabled(!sheet.canFind)
                .help("Looks up pictures for the artists without one: your library's folders, Deezer and Wikimedia Commons. Only the artist's name is sent.")
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { sheet.apply() }
                .keyboardShortcut(.defaultAction)
                .tint(theme.orange)
                .disabled(!sheet.canApply)
                .help("Saves your choices, and writes the ready pictures to the iPod when artist pictures are on for it: one picture until you mark check M5 passed in Preferences ▸ Devices, then all of them.")
        }
    }

    private var defaultFooter: String {
        if sheet.isPreview { return "Preview: nothing is fetched or written." }
        return sheet.edits.isEmpty ? "Nothing is looked up until you press Find Missing."
            : "\(sheet.edits.count) change\(sheet.edits.count == 1 ? "" : "s") waiting for Apply."
    }
}

private struct ArtistPictureCell: View {
    @Environment(\.carbon) private var theme
    let row: ArtistPictureRow
    @ObservedObject var sheet: ArtistPicturesSheetModel
    let tile: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            picture
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.name)
                    .font(CarbonFont.sans(13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.name)
                Spacer(minLength: 0)
                actions
            }
            Text("\(row.trackCount) track\(row.trackCount == 1 ? "" : "s")")
                .font(CarbonFont.mono(10))
                .foregroundStyle(theme.ink3)
            if row.state == .check {
                candidates
            }
            if let note {
                Text(note)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.hair.opacity(0.5), lineWidth: 1))
        .task(id: "\(row.id)|\(row.state.rawValue)|\(row.badge)|\(sheet.thumbnailGeneration)") {
            await sheet.loadThumbnail(for: row)
        }
    }

    private var picture: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.well)
            if let image = sheet.thumbnails[row.id], row.state == .ready || row.state == .onDevice {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: row.state == .unnameable ? "questionmark.square.dashed" : "person.crop.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.ink4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            badge
                .padding(6)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("\(row.name), \(row.badge.lowercased())")
    }

    private var badge: some View {
        Text(row.badge)
            .font(CarbonFont.mono(8.5, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(badgeInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(badgeFill))
    }

    private var badgeInk: Color {
        switch row.state {
        case .ready, .check: return .white
        case .onDevice, .none, .rejected, .unnameable: return theme.ink2
        }
    }

    private var badgeFill: Color {
        switch row.state {
        case .ready: return theme.orange
        case .check: return theme.orange.opacity(0.75)
        case .onDevice, .none, .rejected, .unnameable: return theme.paper.opacity(0.92)
        }
    }

    private var candidates: some View {
        HStack(spacing: 6) {
            ForEach(row.candidates.prefix(5), id: \.self) { candidate in
                Button { sheet.accept(candidate, for: row) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.well)
                        if let image = sheet.candidateThumbnails[candidate.imageURL] {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo").foregroundStyle(theme.ink4)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Accept this picture from \(candidate.source.displayName)"
                      + (candidate.credit.map { ": \(ArtistPictureCell.creditLine($0))" } ?? ""))
                .task(id: candidate.imageURL) { await sheet.loadCandidateThumbnail(candidate) }
            }
        }
    }

    private var actions: some View {
        Menu {
            if row.state == .check {
                ForEach(Array(row.candidates.prefix(5).enumerated()), id: \.offset) { index, candidate in
                    Button("Accept \(candidate.source.displayName) picture \(index + 1)") { sheet.accept(candidate, for: row) }
                }
                Divider()
            }
            Button("Choose File…") { sheet.chooseFile(for: row) }
                .disabled(row.state == .unnameable || row.state == .onDevice)
            Button("Don't Send to iPod") { sheet.noPicture(for: row) }
                .disabled(row.state == .unnameable || row.state == .rejected || row.state == .onDevice)
            // A stored photo is the artist's, kept on the artist page: Clear
            // takes back only what this sheet set.
            Button("Clear") { sheet.clear(row) }
                .disabled(row.state == .unnameable || row.state == .onDevice || row.state == .none
                          || (row.state == .ready && sheet.edits[row.id] == nil))
            if row.state == .none, row.notFoundAt != nil {
                Divider()
                Button("Look Again") { sheet.lookAgain(row) }
                    .disabled(sheet.isFinding || sheet.isApplying)
            }
            if row.state == .onDevice, sheet.isMounted, sheet.crateDiggerPictures[row.id] != nil {
                Divider()
                Button("Remove from iPod") { sheet.removeFromIPod(row) }
                    .disabled(sheet.isFinding || sheet.isApplying)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a picture for \(row.name)")
    }

    /// One caption: where the picture is, its credit, or why there is none.
    private var note: String? {
        switch row.state {
        case .onDevice:
            guard let path = row.devicePath else {
                return "The iPod may already show a picture, so CrateDigger leaves this artist alone."
            }
            if sheet.crateDiggerPictures[row.id] != nil {
                return "On the iPod: \(path). CrateDigger wrote it; Remove from iPod takes it off."
            }
            return "On the iPod: \(path). CrateDigger never covers a picture already there."
        case .ready:
            return row.credit.map { "Commons: " + Self.creditLine($0) }
        case .check:
            let credited = row.candidates.compactMap(\.credit).first
            return "Pick the right one." + (credited.map { " Commons: " + Self.creditLine($0) } ?? "")
        case .none:
            return row.notFoundAt.map {
                "Nothing found on \($0.formatted(date: .abbreviated, time: .omitted)). Find Missing skips it "
                    + "for 30 days; Look Again asks now."
            }
        case .rejected:
            return row.badge == "NO PICTURE"
                ? "No photo, as you chose on the artist page."
                : "Not sent to the iPod, as you chose. The artist page still shows the photo."
        case .unnameable:
            // PodBox keys a name with no letter or digit 0 and never shows a
            // picture for it (see `ArtistPicturePlanner`); the artist page can.
            return PodBoxArtName.key(row.name) == 0 && PodBoxArtName.altKey(row.name) == 0
                ? "PodBox shows no picture for a name with no letters or digits. The artist page in CrateDigger still can."
                : "PodBox cannot match a picture to this name."
        }
    }

    static func creditLine(_ credit: ArtistPictureCredit) -> String {
        [credit.fileName, credit.licence, credit.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

private extension ArtistPictureSourceID {
    var displayName: String {
        switch self {
        case .userFile: return "your file"
        case .libraryFolder: return "your library"
        case .deezer: return "Deezer"
        case .commons: return "Wikimedia Commons"
        case .fanartTV: return "fanart.tv"
        case .discogs: return "Discogs"
        case .theAudioDB: return "TheAudioDB"
        }
    }
}
