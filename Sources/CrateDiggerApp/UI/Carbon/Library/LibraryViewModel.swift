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

    @Published var oledView: OLEDView = .nowPlaying
    @Published var scanProgress: ScanProgress = .idle
    @Published var conversionProgress: ConversionProgressSnapshot = .idle

    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var playbackCurrentIndex: Int?
    @Published private(set) var playbackCurrentTime: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var playbackErrorMessage: String?

    @Published var playbackVolume: Double = 0.8 {
        didSet { playback.setVolume(playbackVolume) }
    }

    @Published var shuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off

    // MARK: - Services

    let playback: PlaybackServiceProtocol
    let scanner: LibraryScanService
    let artworkService: ArtworkService

    // MARK: - Private

    private var playbackQueue: [LoadedTrack] = []
    private var scanTask: Task<Void, Never>?

    // MARK: - Init

    init(
        playback: PlaybackServiceProtocol = PlaybackService(),
        artworkService: ArtworkService = ArtworkService(),
        scanner: LibraryScanService? = nil
    ) {
        self.playback = playback
        self.artworkService = artworkService

        if let scanner {
            self.scanner = scanner
        } else {
            let toolLocator = ExternalToolLocator()
            if let resolved = toolLocator.resolveOptional(.ffprobe),
               let probe = try? MetadataProbeService(ffprobeExecutableURL: resolved.url) {
                self.scanner = LibraryScanService(artworkService: artworkService, metadataProbe: probe)
            } else {
                self.scanner = LibraryScanService(artworkService: artworkService, metadataProbe: nil)
            }
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
        ConversionOptionsSelection(
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
            Task { @MainActor in self?.playbackErrorMessage = message }
        }
    }
}
