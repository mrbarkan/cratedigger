import AppKit
import CrateDiggerCore
import Foundation
import SwiftUI

enum OLEDView: String, CaseIterable, Codable, Sendable {
    case nowPlaying
    case vu
    case conversion
    case scan

    var label: String {
        switch self {
        case .nowPlaying: return "Now"
        case .vu:         return "VU"
        case .conversion: return "Cnvrt"
        case .scan:       return "Scan"
        }
    }
}

enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

struct ScanProgress: Equatable, Sendable {
    var folderName: String?
    var filesProbed: Int
    var totalCandidates: Int?
    var isRunning: Bool

    static let idle = ScanProgress(folderName: nil, filesProbed: 0, totalCandidates: nil, isRunning: false)
}

struct ConversionProgressSnapshot: Equatable, Sendable {
    var jobsCompleted: Int
    var jobsTotal: Int
    var currentFilename: String?
    var isRunning: Bool

    static let idle = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 0, currentFilename: nil, isRunning: false)
}

@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var index: LibraryIndex = .empty
    @Published var selectedArtistID: String?
    @Published var selectedAlbumID: String?
    @Published var selectedTrackID: UUID?

    @Published var oledView: OLEDView = .nowPlaying {
        didSet {
            prefs.savedOLEDView = oledView.rawValue
            handleOLEDViewChange(from: oldValue, to: oledView)
        }
    }

    private func handleOLEDViewChange(from old: OLEDView, to new: OLEDView) {
        // Entering convert mode: auto-collapse the browser to its compact
        // context view so the patch bay gets stage space. Only auto-collapse
        // if the user hadn't already collapsed it manually — and remember we
        // did this so we can restore on exit.
        if new == .conversion && old != .conversion {
            if !browserCollapsed {
                browserCollapsed = true
                browserAutoCollapsedForConvert = true
            }
        } else if old == .conversion && new != .conversion {
            if browserAutoCollapsedForConvert {
                browserCollapsed = false
                browserAutoCollapsedForConvert = false
            }
        }
    }
    @Published var scanProgress: ScanProgress = .idle
    @Published var conversionProgress: ConversionProgressSnapshot = .idle

    /// Patch-bay state. Mutated directly by the Carbon convert panel via
    /// SwiftUI bindings; persisted to prefs on every change so the patch bay
    /// remembers its setting across launches and lines up with what the
    /// legacy options sheet would have written.
    @Published var conversionSelection: ConversionOptionsSelection = ConversionOptionsSelection(
        batchScope: .selectedTracks,
        outputFormat: .aac,
        bitrate: 192,
        sampleRate: 44_100,
        artworkMaxDimension: 1024,
        folderStructureMode: .flat,
        applyMode: .applyAll,
        templatePreset: .artistYearAlbum,
        tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder
    ) {
        didSet { prefs.saveLastConversionSelection(PersistedConversionSelection(conversionSelection)) }
    }

    /// Sources, Browser, and Inspector wells can each collapse so the user
    /// can give the other columns most of the chassis width. Sources and
    /// Inspector collapse to thin rotated-title rails; Browser collapses to
    /// a compact "now-playing context" track list.
    @Published var sourcesCollapsed: Bool = false
    @Published var browserCollapsed: Bool = false
    @Published var inspectorCollapsed: Bool = false

    /// User asked to enter convert mode: auto-collapse the browser so the
    /// patch bay gets stage room. This flag tracks whether the auto-collapse
    /// applied so we know to restore the user's previous state when leaving.
    private var browserAutoCollapsedForConvert: Bool = false

    /// Invariant-preserving setters: at most one of {browser, inspector} can
    /// be collapsed at a time so the chassis main area always has at least
    /// one flex pane absorbing leftover width — no dead space.
    func toggleBrowserCollapsed() {
        if !browserCollapsed && inspectorCollapsed {
            inspectorCollapsed = false
        }
        browserCollapsed.toggle()
    }

    func toggleInspectorCollapsed() {
        if !inspectorCollapsed && browserCollapsed {
            browserCollapsed = false
        }
        inspectorCollapsed.toggle()
    }

    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var playbackCurrentIndex: Int?
    @Published private(set) var playbackCurrentTime: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var playbackErrorMessage: String?
    @Published var appAlert: AppAlert?
    @Published private(set) var albumsFetchingArtwork: Set<String> = []

    @Published var playbackVolume: Double = 0.8 {
        didSet { playback.setVolume(playbackVolume) }
    }

    @Published var shuffleEnabled: Bool = false {
        didSet { prefs.savedShuffleEnabled = shuffleEnabled }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { prefs.savedRepeatMode = repeatMode.rawValue }
    }

    // MARK: - Services

    let playback: PlaybackServiceProtocol
    let scanner: LibraryScanService
    let artworkService: ArtworkService
    let remoteArtworkService: RemoteArtworkService
    let prefs: PreferencesStore

    // MARK: - Private

    private var playbackQueue: [LoadedTrack] = []
    private var scanTask: Task<Void, Never>?
    var conversionTask: Task<Void, Never>?
    weak var activeConversionService: ConversionService?

    // MARK: - Init

    init(
        playback: PlaybackServiceProtocol = PlaybackService(),
        artworkService: ArtworkService = ArtworkService(),
        remoteArtworkService: RemoteArtworkService = RemoteArtworkService(),
        scanner: LibraryScanService? = nil,
        prefs: PreferencesStore = .shared
    ) {
        self.playback = playback
        self.artworkService = artworkService
        self.remoteArtworkService = remoteArtworkService
        self.prefs = prefs

        if let scanner {
            self.scanner = scanner
        } else {
            let toolLocator = ExternalToolLocator()
            if let resolved = toolLocator.resolveOptional(.ffprobe) {
                do {
                    let probe = try MetadataProbeService(ffprobeExecutableURL: resolved.url)
                    self.scanner = LibraryScanService(
                        artworkService: artworkService,
                        remoteArtworkService: remoteArtworkService,
                        metadataProbe: probe
                    )
                } catch {
                    AppLog.tools.warning("Found ffprobe at \(resolved.url.path, privacy: .public) but could not initialize MetadataProbeService: \(String(describing: error), privacy: .public)")
                    self.scanner = LibraryScanService(
                        artworkService: artworkService,
                        remoteArtworkService: remoteArtworkService,
                        metadataProbe: nil
                    )
                }
            } else {
                AppLog.tools.notice("ffprobe not found via ExternalToolLocator; scan will use AVFoundation metadata only")
                self.scanner = LibraryScanService(
                    artworkService: artworkService,
                    remoteArtworkService: remoteArtworkService,
                    metadataProbe: nil
                )
            }
        }

        if let saved = prefs.savedOLEDView, let view = OLEDView(rawValue: saved) {
            oledView = view
        }
        shuffleEnabled = prefs.savedShuffleEnabled
        if let saved = prefs.savedRepeatMode, let mode = RepeatMode(rawValue: saved) {
            repeatMode = mode
        }

        // Hydrate the conversion patch-bay selection from prefs without
        // tripping the didSet (which would just write the same data right
        // back during init).
        if let persisted = prefs.savedLastConversionSelection(as: PersistedConversionSelection.self),
           let restored = persisted.materialize() {
            conversionSelection = restored
        }

        wirePlaybackBindings()
        playback.setVolume(playbackVolume)
    }

    // MARK: - Selection helpers

    var selectedArtist: Artist? {
        guard let id = selectedArtistID else { return index.artists.first }
        return index.artist(id: id) ?? index.artists.first
    }

    var selectedAlbum: Album? {
        let albums = selectedArtist?.albums ?? []
        guard let id = selectedAlbumID else { return albums.first }
        return albums.first(where: { $0.id == id }) ?? albums.first
    }

    var visibleTracks: [LoadedTrack] {
        selectedAlbum?.tracks ?? []
    }

    var selectedTrack: LoadedTrack? {
        guard let id = selectedTrackID else { return visibleTracks.first }
        return visibleTracks.first(where: { $0.track.id == id }) ?? visibleTracks.first
    }

    var nowPlayingTrack: LoadedTrack? {
        guard let i = playbackCurrentIndex, i >= 0, i < playbackQueue.count else { return nil }
        return playbackQueue[i]
    }

    // MARK: - Folder loading

    func openFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Choose music folders to scan"
        panel.prompt = "Open"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        loadFolders(urls)
    }

    func loadFolders(_ urls: [URL]) {
        persistFolderBookmarks(urls)

        scanTask?.cancel()
        scanProgress = ScanProgress(folderName: urls.first?.lastPathComponent, filesProbed: 0, totalCandidates: nil, isRunning: true)
        playback.load(queue: [], startIndex: 0, autoPlay: false)
        playbackQueue = []

        scanTask = Task { [weak self] in
            guard let self else { return }
            var collected: [LoadedTrack] = []
            for url in urls {
                if Task.isCancelled { break }
                let scanned = await self.scanner.scanFolder(url)
                collected.append(contentsOf: scanned)
                await MainActor.run {
                    self.scanProgress = ScanProgress(
                        folderName: url.lastPathComponent,
                        filesProbed: collected.count,
                        totalCandidates: nil,
                        isRunning: true
                    )
                }
            }
            if Task.isCancelled { return }

            let merged = LibraryViewModel.deduplicate(tracks: collected)
            let built = LibraryIndex.build(from: merged)

            await MainActor.run {
                self.index = built
                self.selectedArtistID = built.artists.first?.id
                self.selectedAlbumID = built.artists.first?.albums.first?.id
                self.selectedTrackID = built.artists.first?.albums.first?.tracks.first?.track.id
                self.scanProgress = ScanProgress(
                    folderName: nil,
                    filesProbed: built.allTracks.count,
                    totalCandidates: built.allTracks.count,
                    isRunning: false
                )
            }
        }
    }

    /// Re-open whichever folders the user had loaded last session. Silently
    /// drops bookmarks that no longer resolve (volume gone, folder deleted).
    func restoreLastFoldersIfPossible() {
        let bookmarks = prefs.savedLibraryFolderBookmarks
        guard !bookmarks.isEmpty else { return }

        var refreshedBookmarks: [Data] = []
        var resolvedURLs: [URL] = []
        for data in bookmarks {
            guard let (refreshed, resolved) = PreferencesStore.refreshBookmarkIfStale(data) else {
                continue
            }
            refreshedBookmarks.append(refreshed)
            resolvedURLs.append(resolved.url)
        }

        if refreshedBookmarks != bookmarks {
            prefs.savedLibraryFolderBookmarks = refreshedBookmarks
        }
        guard !resolvedURLs.isEmpty else {
            AppLog.library.notice("No saved library folders could be re-opened on launch")
            return
        }
        AppLog.library.info("Restoring \(resolvedURLs.count, privacy: .public) saved library folder(s)")
        loadFolders(resolvedURLs)
    }

    private func persistFolderBookmarks(_ urls: [URL]) {
        var data: [Data] = []
        for url in urls {
            do {
                let bookmark = try PreferencesStore.makeBookmark(for: url)
                data.append(bookmark)
            } catch {
                AppLog.library.warning("Could not bookmark \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        prefs.savedLibraryFolderBookmarks = data
    }

    private static func deduplicate(tracks: [LoadedTrack]) -> [LoadedTrack] {
        var seen = Set<String>()
        var result: [LoadedTrack] = []
        result.reserveCapacity(tracks.count)
        for track in tracks {
            let key = track.track.fileURL.standardizedFileURL.path
            if seen.insert(key).inserted { result.append(track) }
        }
        return result
    }

    // MARK: - Playback actions

    func playTrack(id: UUID) {
        let queue = currentAlbumQueue()
        guard let startIndex = queue.firstIndex(where: { $0.track.id == id }) else { return }
        playbackQueue = queue
        let queueItems = queue.map { loaded -> PlaybackQueueItem in
            PlaybackQueueItem(
                url: loaded.track.fileURL,
                title: loaded.track.title,
                artist: loaded.track.artist,
                album: loaded.track.album,
                durationSeconds: loaded.track.durationSeconds
            )
        }
        playback.load(queue: queueItems, startIndex: startIndex, autoPlay: true)
    }

    func togglePlayPause() {
        if case .idle = playbackState, let track = visibleTracks.first {
            playTrack(id: track.track.id)
            return
        }
        playback.togglePlayPause()
    }

    func next() { playback.next() }
    func previous() { playback.previous() }
    func rewind8s()  { playback.seek(toSeconds: max(0, playbackCurrentTime - 8)) }
    func forward8s() { playback.seek(toSeconds: min(playbackDuration, playbackCurrentTime + 8)) }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        playbackVolume = clamped
    }

    // MARK: - Conversion entry

    func makeInitialConversionSelection() -> ConversionOptionsSelection {
        if let persisted = prefs.savedLastConversionSelection(as: PersistedConversionSelection.self),
           let selection = persisted.materialize() {
            return selection
        }
        return ConversionOptionsSelection(
            batchScope: .selectedTracks,
            outputFormat: .aac,
            bitrate: 192,
            sampleRate: 44_100,
            artworkMaxDimension: 1024,
            folderStructureMode: .flat,
            applyMode: .applyAll,
            templatePreset: .artistYearAlbum,
            tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder
        )
    }

    func toggleShuffle() { shuffleEnabled.toggle() }

    // MARK: - Conversion patch-bay queue stats

    /// Tracks the patch bay's CONVERT button will dispatch when armed. Driven
    /// by the same scope rule the conversion runner uses, so the OLED queue
    /// readout stays in sync with what actually runs.
    var conversionQueueTracks: [LoadedTrack] {
        tracksForBatchScope(conversionSelection.batchScope)
    }

    var conversionQueueDurationSeconds: Double {
        conversionQueueTracks.reduce(0) { $0 + $1.track.durationSeconds }
    }

    var conversionEstimatedOutputBytes: Int64 {
        let bitrate = conversionSelection.bitrate ?? 192
        // For lossless we don't know — fall back to a conservative 5x lossy.
        let effective = isLosslessSelectedFormat ? bitrate * 5 : bitrate
        return Int64(conversionQueueDurationSeconds * Double(effective) * 1000.0 / 8.0)
    }

    var isLosslessSelectedFormat: Bool {
        switch conversionSelection.outputFormat {
        case .alac, .flac, .wav, .aiff: return true
        case .mp3, .aac, .ogg, .opus:    return false
        }
    }

    var conversionDestinationDisplayPath: String {
        guard let url = currentConversionDestinationURL else {
            return "~/Music/CrateDigger Library/"
        }
        return Self.tildeShortened(url.path) + "/"
    }

    var currentConversionDestinationURL: URL? {
        guard let bookmark = prefs.savedOutputDestinationBookmark else { return nil }
        guard let (refreshed, resolved) = PreferencesStore.refreshBookmarkIfStale(bookmark) else {
            return nil
        }
        if refreshed != bookmark {
            prefs.savedOutputDestinationBookmark = refreshed
        }
        return resolved.url
    }

    func chooseConversionDestinationViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose where converted files go"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? PreferencesStore.makeBookmark(for: url) {
            prefs.savedOutputDestinationBookmark = data
            // Force a redraw — the destination isn't @Published since we read
            // it through the bookmark each time.
            objectWillChange.send()
        }
    }

    func triggerConversionFromPatchBay() {
        guard let host = NSApp.keyWindow?.contentViewController else { return }
        runConversion(selection: conversionSelection, presentingFrom: host)
    }

    private static func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Remote artwork fetch

    func isFetchingArtwork(for album: Album) -> Bool {
        albumsFetchingArtwork.contains(album.id)
    }

    func fetchRemoteArtwork(for album: Album) {
        let albumID = album.id
        guard !albumsFetchingArtwork.contains(albumID) else { return }
        albumsFetchingArtwork.insert(albumID)

        let artistName = album.artistName
        let albumTitle = album.title

        Task { [weak self, remoteArtworkService] in
            do {
                let asset = try await remoteArtworkService.fetchArtwork(
                    artist: artistName,
                    album: albumTitle
                )
                await MainActor.run {
                    guard let self else { return }
                    self.albumsFetchingArtwork.remove(albumID)
                    self.applyFetchedArtwork(asset, toAlbumID: albumID)
                }
            } catch {
                AppLog.library.warning("Remote artwork fetch failed for \(albumTitle, privacy: .public): \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    guard let self else { return }
                    self.albumsFetchingArtwork.remove(albumID)
                    self.appAlert = .error(
                        title: "No artwork found",
                        message: (error as? LocalizedError)?.errorDescription
                            ?? "iTunes returned no match. Try a different album, or drop a cover.jpg next to the file."
                    )
                }
            }
        }
    }

    private func applyFetchedArtwork(_ asset: ArtworkAsset, toAlbumID albumID: String) {
        artworkService.ingest(asset)

        guard let album = index.album(id: albumID) else { return }
        let affected = Set(album.tracks.map { $0.track.id })

        let updatedTracks: [LoadedTrack] = index.allTracks.map { loaded in
            guard affected.contains(loaded.track.id) else { return loaded }
            var newTrack = loaded.track
            newTrack.artworkSource = .remote
            newTrack.artworkHash = asset.hash
            newTrack.artworkDimensions = asset.dimensions
            var newMetadata = loaded.metadata
            newMetadata.artwork = asset
            return LoadedTrack(track: newTrack, metadata: newMetadata)
        }

        index = LibraryIndex.build(from: updatedTracks)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func currentAlbumQueue() -> [LoadedTrack] {
        if shuffleEnabled, let album = selectedAlbum {
            return album.tracks.shuffled()
        }
        return visibleTracks
    }

    // MARK: - Bindings

    private func wirePlaybackBindings() {
        playback.onStateChange = { [weak self] state in
            Task { @MainActor in self?.playbackState = state }
        }
        playback.onCurrentIndexChange = { [weak self] index in
            Task { @MainActor in self?.playbackCurrentIndex = index }
        }
        playback.onTimeChange = { [weak self] current, duration in
            Task { @MainActor in
                self?.playbackCurrentTime = current
                self?.playbackDuration = duration
            }
        }
        playback.onError = { [weak self] message in
            Task { @MainActor in
                self?.playbackErrorMessage = message
                AppLog.playback.error("Playback failure: \(message, privacy: .public)")
                self?.appAlert = .error(
                    title: "Couldn't play this track",
                    message: message
                )
            }
        }
    }
}
