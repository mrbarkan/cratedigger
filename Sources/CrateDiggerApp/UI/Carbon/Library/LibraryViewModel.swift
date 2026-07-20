import AppKit
import CryptoKit
import CrateDiggerCore
import Foundation
import SwiftUI

enum OLEDView: String, CaseIterable, Codable, Sendable {
    case nowPlaying
    case vu
    case conversion
    case scan
    case remoteSync
    case cdRip
    case devices

    var label: String {
        switch self {
        case .nowPlaying: return "Now"
        case .vu:         return "VU"
        case .conversion: return "Cnvrt"
        case .scan:       return "Scan"
        case .remoteSync: return "Sync"
        case .cdRip:      return "CD"
        case .devices:    return "Dev"
        }
    }
}

enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

/// Isolated playback time state. Views that show the moving playhead observe
/// this object directly; everything else observing `LibraryViewModel` stays
/// untouched by the 5Hz tick.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    @Published fileprivate(set) var duration: Double = 0
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

enum LibrarySource: Hashable, Sendable {
    case localAll
    case localCrate(name: String)
    case prepCrate
    case remote
    case playlist(name: String)
    case cd(volumePath: String)
    /// A mounted external device (USB drive, SD card, Rockbox iPod) browsed by
    /// its volume path.
    case device(volumePath: String)
    /// Radio / Streams. `nil` category == "All Streams"; otherwise filtered to
    /// one source category ("YT Live" / "YT Records").
    case radio(category: RadioCategory?)
}

/// Which backend plays YouTube streams. Resolved from `PreferencesStore.streamEngine`
/// plus yt-dlp availability (see `LibraryViewModel.resolveActiveEngineKind`).
enum RadioEngineKind: String {
    case webview
    case native
}

@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var index: LibraryIndex = .empty {
        didSet { recomputeSortedCollections() }
    }
    @Published var selectedArtistID: String?
    @Published var selectedAlbumID: String?
    @Published var selectedTrackID: UUID?

    /// Multi-selection sets for batch actions (⌘/⇧-click, ⌘A). The three are kept
    /// mutually exclusive — you're selecting artists *or* albums *or* tracks — while
    /// `selectedArtistID` / `selectedAlbumID` / `selectedTrackID` stay the "anchor"
    /// (last-clicked) that drives the Inspector and the ⇧-click range origin.
    @Published var selectedArtistIDs: Set<String> = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var selectedTrackIDs: Set<UUID> = []

    @Published var oledView: OLEDView = .nowPlaying {
        didSet {
            prefs.savedOLEDView = oledView.rawValue
        }
    }

    @Published var scanProgress: ScanProgress = .idle
    /// The OLED view to restore after an add-to-crate import status finishes.
    private var importStatusReturnOLED: OLEDView?
    @Published var conversionProgress: ConversionProgressSnapshot = .idle

    /// Set while a "send to device (convert)" hand-off owns the CNVRT cockpit: the
    /// device folder is the destination and its tracks are the queue. Cleared when
    /// the run finishes or the user leaves convert mode.
    @Published var pendingDeviceConversion: PendingDeviceConversion?

    /// The conversion selection to restore after a device convert-transfer, which
    /// temporarily seeds the cockpit with the device's saved format + folder layout
    /// so files land in the device's folder pattern instead of dumped flat.
    var conversionSelectionBeforeDevice: ConversionOptionsSelection?

    /// Exit a device convert hand-off: drop the pending transfer and restore the
    /// user's normal conversion selection.
    func clearPendingDeviceConversion() {
        pendingDeviceConversion = nil
        if let restore = conversionSelectionBeforeDevice {
            conversionSelectionBeforeDevice = nil
            conversionSelection = restore
        }
    }

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
        didSet { prefs.saveLastConversionSelection(conversionSelection) }
    }

    @Published var sourcesCollapsed: Bool = false
    @Published var browserCollapsed: Bool = false
    @Published var inspectorCollapsed: Bool = false
    @Published var showArtworkGallery: Bool = false
    /// Columns the gallery grid is currently laying out. Published by the view
    /// (only it knows the pane width) and read by ↑/↓ arrow nav, which has to
    /// move by a whole row.
    @Published var galleryColumnsPerRow: Int = 1

    /// Tag-editor sheet target — one track (full editor) or many (batch editor).
    /// Presented from `MainShell`, so it works from any row's context menu.
    @Published var tagEditTarget: TagEditTarget?

    /// Album whose artwork to show in the floating viewer. A transient trigger:
    /// `MainShell` observes it, presents the viewer window, then clears it.
    @Published var artworkViewerAlbum: Album?

    /// Open the tag editor for a set of tracks (album/artist context menus pass
    /// all their tracks; the inspector passes the single selected track).
    func editTags(for tracks: [LoadedTrack]) {
        guard !tracks.isEmpty else { return }
        tagEditTarget = TagEditTarget(tracks: tracks)
    }

    /// Show an album's artwork (cover + booklet) in the floating viewer.
    func showArtwork(for album: Album) {
        artworkViewerAlbum = album
    }

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

    /// The 5Hz time tick lives on its own object so it only re-renders the few
    /// views that display time (POSITION dial, OLED clock, mini player) instead
    /// of invalidating every observer of this view model — at 14k tracks the
    /// flat track list alone made that a constant-CPU render storm.
    let playbackClock = PlaybackClock()
    private(set) var playbackCurrentTime: Double {
        get { playbackClock.currentTime }
        set {
            // Publish at display resolution: the OLED/mini player show M:SS and
            // the dial moves ~1px per second, so the 5Hz sub-second ticks were
            // re-rendering identical pixels. Zero always lands (stop/track change).
            if newValue == 0 || abs(playbackClock.currentTime - newValue) >= 0.5 {
                playbackClock.currentTime = newValue
            }
        }
    }
    private(set) var playbackDuration: Double {
        get { playbackClock.duration }
        set {
            if newValue == 0 || abs(playbackClock.duration - newValue) >= 0.5 {
                playbackClock.duration = newValue
            }
        }
    }

    /// Last elapsed/rate pushed to MPNowPlayingInfoCenter, with the wall time of
    /// the push. The system extrapolates elapsed from rate × wall clock on its
    /// own, so we only re-push when reality diverges (a seek/jump) instead of
    /// on every 0.2s tick — each push is IPC to mediaremoted, and 5/s for the
    /// whole of playback showed up as constant background churn.
    var nowPlayingElapsedAnchor: (elapsed: Double, wall: Date, rate: Double)?

    /// While the user drags (or scroll-seeks) the position dial, the in-progress
    /// fraction (0–1) so the OLED time can follow the scrub before the seek
    /// commits. Nil when not scrubbing.
    @Published var scrubbingFraction: Double?

    /// Elapsed time to display: the scrub target while scrubbing, else the live
    /// playback time.
    var displayedCurrentTime: Double {
        if let fraction = scrubbingFraction { return fraction * playbackDuration }
        return playbackCurrentTime
    }

    /// When on, scrolling over the POSITION dial seeks the playhead.
    @Published var scrubLockEnabled: Bool = false {
        didSet { prefs.savedScrubLockEnabled = scrubLockEnabled }
    }

    /// Mini player art treatment (CD / Vinyl / Album Cover). Persisted.
    @Published var miniPlayerArtMode: MiniPlayerArtMode = .disc {
        didSet { prefs.savedMiniPlayerArtMode = miniPlayerArtMode.rawValue }
    }

    /// First-run onboarding sheet — shown when setup hasn't completed.
    @Published var showingOnboarding: Bool = false

    /// Visual welcome tour — shown before folder setup on the very first
    /// launch, and replayable from Help ▸ Welcome Tour or Preferences.
    @Published var showingWelcomeTour: Bool = false

    private var scrubReleaseWorkItem: DispatchWorkItem?
    private var pendingSeekTargetSeconds: Double?

    /// Commit a scrub to `fraction` and hold the OLED preview on the target until
    /// playback actually reaches it — otherwise the readout blinks back to the
    /// old position between releasing and the seek landing. A fallback timer
    /// clears the preview if no time update arrives (e.g. while paused).
    func commitScrubSeek(toFraction fraction: Double) {
        guard playbackDuration > 0 else { seek(toFraction: fraction); return }
        let target = min(max(fraction, 0), 1)
        scrubbingFraction = target
        pendingSeekTargetSeconds = target * playbackDuration
        seek(toFraction: target)
        scrubReleaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scrubbingFraction = nil
            self?.pendingSeekTargetSeconds = nil
        }
        scrubReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// One scroll-seek step (a fraction delta from the locked POSITION dial).
    func scrollSeek(byFraction delta: Double) {
        guard playbackDuration > 0 else { return }
        let base = scrubbingFraction ?? (playbackCurrentTime / playbackDuration)
        commitScrubSeek(toFraction: base + delta)
    }

    /// Clear the scrub preview once playback has reached the committed target,
    /// so the OLED hands back to the live time without a blink.
    private func clearScrubPreviewIfSeekLanded(_ current: Double) {
        guard let target = pendingSeekTargetSeconds else { return }
        if abs(current - target) < 0.75 {
            scrubbingFraction = nil
            pendingSeekTargetSeconds = nil
            scrubReleaseWorkItem?.cancel()
        }
    }
    @Published var appAlert: AppAlert?
    /// Transient confirmation shown on the OLED glass (tag saves etc.) instead
    /// of a modal alert; auto-clears after a couple of seconds.
    @Published var oledNotice: String?
    private var oledNoticeClearTask: Task<Void, Never>?
    // Not private(set): transient UI state — LibraryViewModel+BatchArtwork
    // marks/clears albums from a different file while a fetch is in flight.
    @Published var albumsFetchingArtwork: Set<String> = []

    /// Global activity registry driving the header status LED. Anything
    /// long-running registers a label; the LED lights while any are active
    /// (or any legacy busy flag below is set).
    @Published private(set) var activities: [UUID: String] = [:]

    @discardableResult
    func beginActivity(_ label: String) -> UUID {
        let id = UUID()
        activities[id] = label
        return id
    }

    func endActivity(_ id: UUID) {
        activities.removeValue(forKey: id)
    }

    /// One switch for "is the app doing something" — new registrations OR the
    /// pre-existing per-feature busy flags, so already-instrumented features
    /// light the LED with no changes.
    var isWorking: Bool {
        !activities.isEmpty
            || scanProgress.isRunning
            || conversionProgress.isRunning
            || isRepairingMetadata
            || !albumsFetchingArtwork.isEmpty
    }

    var activityLabels: [String] {
        Array(activities.values).sorted()
    }

    @Published var playbackVolume: Double = 0.8 {
        didSet {
            applyVolumeToEngines()
            prefs.savedPlaybackVolume = playbackVolume
        }
    }

    /// Apply the dB-curved fader position to the engines: the ≤0 dB part rides
    /// `player.volume`, the >0 dB part (up to +5 dB) is real makeup gain in the
    /// audio tap. Radio has no tap, so it caps at unity. See `VolumeCurve`.
    func applyVolumeToEngines() {
        playback.setVolume(VolumeCurve.playerVolume(forPosition: playbackVolume))
        playback.setMasterGain(VolumeCurve.makeupGain(forPosition: playbackVolume))
        radioEngine?.setVolume(VolumeCurve.playerVolume(forPosition: playbackVolume))
    }

    @Published var shuffleEnabled: Bool = false {
        didSet { prefs.savedShuffleEnabled = shuffleEnabled }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            prefs.savedRepeatMode = repeatMode.rawValue
            // Auto-advance lives in Core — without this forward the transport
            // button was purely cosmetic.
            playback.repeatMode = PlaybackRepeatMode(rawValue: repeatMode.rawValue) ?? .off
        }
    }
    @Published var cdAnimationSpeed: CDAnimationSpeed = .fast {
        didSet { prefs.cdAnimationSpeed = cdAnimationSpeed }
    }

    /// EQ preset label (OLED readout + view-switcher EQ button). Cycling one now
    /// applies its real gain curve to the working equalizer.
    @Published var eqPreset: EQPreset = .flat

    /// Working equalizer state — 12 per-band gains in dB + master enable. Drives
    /// the footer EQ panel display *and* real audio (via the playback tap).
    @Published var eqEnabled: Bool = false { didSet { eqDidChange() } }
    @Published var eqGains: [Double] = Array(repeating: 0, count: EqualizerProcessor.bandCount) {
        didSet { eqDidChange() }
    }
    /// Presents the graphic-EQ editor sheet (opened by clicking the footer EQ panel).
    @Published var showingEQEditor = false

    /// The footer EQ button: cycle to the next preset, apply its curve, and turn
    /// the EQ on so it's audible (the flat preset is transparent anyway).
    func cycleEQPreset() {
        let all = EQPreset.allCases
        let idx = all.firstIndex(of: eqPreset) ?? 0
        eqPreset = all[(idx + 1) % all.count]
        eqGains = eqPreset.gainCurve()
        eqEnabled = true
    }

    private func eqDidChange() {
        prefs.savedEQEnabled = eqEnabled
        prefs.savedEQGains = eqGains
        playback.setEqualizer(enabled: eqEnabled, gains: eqGains)
    }

    private func setupEqualizerObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerEQChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadEqualizerFromPrefs() }
        }
    }

    /// Reload EQ from prefs (e.g. after the Settings panel edits it) and apply.
    func reloadEqualizerFromPrefs() {
        let saved = prefs.savedEQGains
        eqGains = saved.count == EqualizerProcessor.bandCount
            ? saved
            : Array(repeating: 0, count: EqualizerProcessor.bandCount)
        eqEnabled = prefs.savedEQEnabled
    }

    /// How the Track column orders the currently shown album.
    @Published var trackSortField: TrackSortField = .trackNumber {
        didSet { prefs.savedTrackSortField = trackSortField.rawValue; recomputeSortedCollections() }
    }
    @Published var trackSortAscending: Bool = true {
        didSet { prefs.savedTrackSortAscending = trackSortAscending; recomputeSortedCollections() }
    }
    @Published var artistSortField: ArtistSortField = .name {
        didSet { prefs.savedArtistSortField = artistSortField.rawValue; recomputeSortedCollections() }
    }
    @Published var artistSortAscending: Bool = true {
        didSet { prefs.savedArtistSortAscending = artistSortAscending; recomputeSortedCollections() }
    }
    @Published var albumSortField: AlbumSortField = .year {
        didSet { prefs.savedAlbumSortField = albumSortField.rawValue; recomputeSortedCollections() }
    }
    @Published var albumSortAscending: Bool = true {
        didSet { prefs.savedAlbumSortAscending = albumSortAscending; recomputeSortedCollections() }
    }
    /// Whether the per-column sort menus are shown in the browser headers.
    @Published var showSortControls: Bool = true {
        didSet { prefs.savedShowSortControls = showSortControls }
    }

    /// How the browser arranges its columns (3-pane / Album·Track / flat Track).
    @Published var browserLayout: BrowserLayout = .full {
        didSet { prefs.savedBrowserLayout = browserLayout.rawValue }
    }

    /// Which browser column the keyboard arrows act on: ↑/↓ move the selection in
    /// it, ←/→ switch columns. Set when a row is clicked; see `LibraryViewModel+ArrowNav`.
    @Published var focusedColumn: BrowserColumn = .track

    // MARK: - New Sources & Playlists State
    @Published var currentSource: LibrarySource = .localAll
    @Published var availableCrates: [String] = []
    @Published var prepCrateTracks: [LoadedTrack] = []
    /// The reserved, auto-created crate — can't be renamed or deleted.
    static let personalCrateName = "Personal Crate"

    @Published var targetCrateName: String = LibraryViewModel.personalCrateName
    /// Cached counts shown in the Sources sidebar. These are recomputed only
    /// when crates change (`refreshCrateCounts()`), NEVER read by decoding
    /// `.cdlib` files inside a SwiftUI body — those files are JSON with
    /// base64-embedded artwork, so decoding them during a render pass (which
    /// the 60fps disc animation triggers constantly) pegs the CPU.
    @Published private(set) var allRecordsCount: Int = 0
    @Published private(set) var crateTrackCounts: [String: Int] = [:]

    /// Decode every crate once and cache its track count + the deduplicated
    /// all-records total. Call this on crate mutations only.
    func refreshCrateCounts() {
        var counts: [String: Int] = [:]
        var all: [LoadedTrack] = []
        for name in availableCrates {
            let tracks = loadCrateTracks(name: name)
            counts[name] = tracks.count
            all.append(contentsOf: tracks)
        }
        crateTrackCounts = counts
        allRecordsCount = LibraryViewModel.deduplicate(tracks: all).count
    }
    @Published var playlists: [Playlist] = []
    @Published var mountedCDs: [AudioCDInfo] = []
    @Published var mountedDevices: [MountedDevice] = []
    @Published var deadTracks: [LoadedTrack] = []
    /// Names of `/Volumes/<name>` drives the library references that aren't
    /// currently mounted. Drives the "offline" row badge. Recomputed only on
    /// volume mount/unmount + at startup (see recomputeOfflineVolumes), which is
    /// the only writer.
    @Published var offlineVolumes: Set<String> = []
    /// Standardized paths of library files that are gone from disk while their
    /// drive is still mounted (moved / renamed / deleted). Drives the "missing"
    /// row badge. Recomputed off the main thread by recomputeMissingFiles().
    @Published var missingTrackKeys: Set<String> = []
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var isCleanupScanning = false
    /// A scan request arrived while one was in flight — run one more pass
    /// when it lands so mode flips mid-scan are never silently dropped.
    private var pendingCleanupRescan = false
    @Published var duplicateScanMode: DuplicateScanMode =
        DuplicateScanMode(rawValue: PreferencesStore.shared.duplicateScanMode ?? "") ?? .strict {
        didSet {
            guard oldValue != duplicateScanMode else { return }
            PreferencesStore.shared.duplicateScanMode = duplicateScanMode.rawValue
            scanForCleanup()
        }
    }
    /// FIX TAGS (metadata repair) run state — see LibraryViewModel+MetadataRepair.
    @Published var isRepairingMetadata = false
    /// Stored-vs-file tag disagreements from the last repair pass; non-empty
    /// presents the review sheet.
    @Published var metadataRepairConflicts: [MetadataRepairConflictGroup] = []
    /// Online release matches for the selection, best-first; non-empty presents
    /// the match review sheet. Nothing is written until the user says so there.
    @Published var metadataMatches: [ReleaseMatch] = []

    // MARK: - Radio / Streams state
    @Published var streams: [StreamSource] = []
    /// nil == All Streams; otherwise the source category currently shown.
    @Published var radioCategoryFilter: RadioCategory?
    @Published var selectedStreamID: String?
    /// Drives the Add-Stream sheet (shared by the sidebar "+" and the radio list "ADD URL").
    @Published var showingAddStreamSheet: Bool = false
    /// Uptime ticker for a live stream (seconds); formatted HH:MM:SS in the OLED.
    @Published var radioUptimeSeconds: Int = 0
    /// Short label for the active stream engine, shown in the OLED ("AUTO"/"NATIVE"/"WEB").
    @Published var radioEngineLabel: String = "AUTO"
    /// Active engine for the current stream; drives whether the OLED shows real codec/buffer.
    @Published var radioEngineKind: RadioEngineKind = .webview

    // MARK: - Record Divider state
    /// The track open in the Record Divider review sheet (a vinyl-side rip).
    @Published var recordDividerTrack: LoadedTrack?
    @Published var showingRecordDividerSheet: Bool = false
    /// Editable working rows in the review sheet (skipped rows have `keep == false`).
    @Published var recordDividerRows: [RecordDividerDraftRow] = []
    /// Detection sensitivity slider, 0 (fewest splits) … 1 (most). Default is
    /// conservative so long songs aren't split internally.
    @Published var recordDividerSensitivity: Double = 0.4
    @Published var recordDividerIsScanning: Bool = false
    /// Hint shown when a scan finds 0–1 breaks (suggest raising sensitivity).
    @Published var recordDividerHint: String?
    /// A marker start to seek to once a just-started divided file is playing
    /// (clicking a sub-track in the browser before its file is loaded).
    var pendingRecordSeekSeconds: Double?
    var pendingRecordSeekTrackID: UUID?

    var isRadioMode: Bool {
        if case .radio = currentSource { return true }
        return false
    }

    /// True when a stream is actually playing/paused — independent of which source
    /// is being browsed. The now-playing OLED + transport follow this (not
    /// `isRadioMode`), so a stream keeps playing and stays controllable while you
    /// browse the library.
    var isStreamActive: Bool {
        radioEngine != nil && playbackState != .idle
    }

    var filteredStreams: [StreamSource] {
        guard let category = radioCategoryFilter else { return streams }
        return streams.filter { category.contains($0) }
    }
    var selectedStream: StreamSource? {
        guard let id = selectedStreamID else { return nil }
        return streams.first { $0.id == id }
    }
    /// Source categories that currently have at least one stream, in a stable
    /// order (sidebar grouping). Empty categories are hidden.
    var streamCategories: [RadioCategory] {
        RadioCategory.allCases.filter { cat in streams.contains { cat.contains($0) } }
    }
    /// Stream count for a category (sidebar trailing count).
    func streamCount(in category: RadioCategory) -> Int {
        streams.filter { category.contains($0) }.count
    }
    /// Chapters of the selected stream (a tracklist for long mixes); empty if none.
    var selectedStreamChapters: [StreamChapter] {
        selectedStream?.chapters ?? []
    }
    /// Index of the chapter currently playing, based on playback position.
    var currentChapterIndex: Int? {
        selectedStream?.chapterIndex(at: playbackCurrentTime)
    }
    var currentChapter: StreamChapter? {
        guard let i = currentChapterIndex, selectedStreamChapters.indices.contains(i) else { return nil }
        return selectedStreamChapters[i]
    }
    let streamStore = StreamStore()
    var radioUptimeTimer: Timer?
    /// Active playback engine while a stream is playing (WebView or native). nil when idle.
    var radioEngine: RadioPlaybackEngine?

    // Cache indexes for fast switching
    private(set) var localIndex: LibraryIndex = .empty
    private var remoteIndex: LibraryIndex = .empty
    private var cdIndex: LibraryIndex = .empty
    /// Scanned device indexes, keyed by volume path — so re-selecting a device
    /// reuses the scan instead of re-walking the disk. Invalidated on unplug
    /// (`refreshDevices`) and on RESCAN (`refreshLibrary`).
    private var deviceIndexCache: [String: LibraryIndex] = [:]
    /// On-disk per-device catalogs so a device opens instantly across launches
    /// (rescan only on RESCAN).
    private let deviceCatalogStore = DeviceCatalogStore()
    private var playlistIndex: LibraryIndex = .empty
    private var prepCrateIndex: LibraryIndex = .empty

    // MARK: - Services

    let playback: PlaybackServiceProtocol
    let scanner: LibraryScanService
    let artworkService: ArtworkService
    let remoteArtworkService: RemoteArtworkService
    /// Online release lookup behind FIX TAGS — see LibraryViewModel+MetadataRepair.
    let matchService: MetadataMatchService
    let prefs: PreferencesStore

    // New services
    let subsonicClient = SubsonicClient()
    let cdRipper = CDRipperService()
    let deviceDetector = DeviceDetectionService()
    let playlistService = PlaylistService()
    let audioOutput = AudioOutputManager()
    let lastFM = LastFMScrobbler()
    var metadataEditor: MetadataEditorService?
    let albumGroupStore = AlbumGroupStore()

    // Last.fm tracking
    private var lastScrobbledTrackID: UUID?
    private var playbackStartTimestamp: Int = 0
    /// Actual listened time, accumulated from time-change deltas — the playhead
    /// position alone would scrobble instantly after a seek to 60%.
    private var listenedSeconds: Double = 0
    private var lastScrobbleTickTime: Double?

    // MARK: - Private

    private var playbackQueue: [LoadedTrack] = []
    private var scanTask: Task<Void, Never>?
    /// Bumped when a new scan starts so progress callbacks from a superseded
    /// scan can't clobber the OLED with stale numbers.
    private var scanGeneration = 0
    var conversionTask: Task<Void, Never>?
    weak var activeConversionService: ConversionService?

    // Keyboard Shortcuts Monitor
    private var localEventMonitor: Any?

    // MARK: - Init

    init(
        playback: PlaybackServiceProtocol = PlaybackService(),
        artworkService: ArtworkService = ArtworkService(store: ArtworkStore(directory: ArtworkStore.defaultDirectory)),
        remoteArtworkService: RemoteArtworkService = RemoteArtworkService(),
        matchService: MetadataMatchService = .live(),
        scanner: LibraryScanService? = nil,
        prefs: PreferencesStore = .shared
    ) {
        self.playback = playback
        self.artworkService = artworkService
        self.remoteArtworkService = remoteArtworkService
        self.matchService = matchService
        self.prefs = prefs

        do {
            self.metadataEditor = try MetadataEditorService()
        } catch {
            AppLog.tools.warning("Could not initialize MetadataEditorService: \(error.localizedDescription)")
        }

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
                    AppLog.tools.warning("Found ffprobe but could not init MetadataProbeService: \(String(describing: error))")
                    self.scanner = LibraryScanService(
                        artworkService: artworkService,
                        remoteArtworkService: remoteArtworkService,
                        metadataProbe: nil
                    )
                }
            } else {
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
        if let savedVolume = prefs.savedPlaybackVolume {
            playbackVolume = min(max(savedVolume, 0), 1)
        }
        // Property observers don't fire during init — forward the restored
        // mode and volume to the playback service explicitly.
        playback.repeatMode = PlaybackRepeatMode(rawValue: repeatMode.rawValue) ?? .off
        applyVolumeToEngines()
        cdAnimationSpeed = prefs.cdAnimationSpeed
        if let savedField = prefs.savedTrackSortField, let field = TrackSortField(rawValue: savedField) {
            trackSortField = field
        }
        trackSortAscending = prefs.savedTrackSortAscending
        if let savedField = prefs.savedArtistSortField, let field = ArtistSortField(rawValue: savedField) {
            artistSortField = field
        }
        artistSortAscending = prefs.savedArtistSortAscending
        if let savedField = prefs.savedAlbumSortField, let field = AlbumSortField(rawValue: savedField) {
            albumSortField = field
        }
        albumSortAscending = prefs.savedAlbumSortAscending
        showSortControls = prefs.savedShowSortControls
        if let savedLayout = prefs.savedBrowserLayout, let layout = BrowserLayout(rawValue: savedLayout) {
            browserLayout = layout
        }
        scrubLockEnabled = prefs.savedScrubLockEnabled
        if let raw = prefs.savedMiniPlayerArtMode, let mode = MiniPlayerArtMode(rawValue: raw) {
            miniPlayerArtMode = mode
        }
        // The tour takes priority; when it dismisses it chains into folder
        // setup (and starter-content install) as needed — see
        // welcomeTourDidDismiss(). "Not seen" covers fresh installs, upgrades,
        // and a tour re-armed from Preferences.
        if !prefs.hasSeenWelcomeTour {
            showingWelcomeTour = true
        } else if !prefs.hasCompletedFirstRunSetup {
            showingOnboarding = true
        }

        if var restored = prefs.savedLastConversionSelection(as: ConversionOptionsSelection.self) {
            if restored.tokenOrder.isEmpty { restored.tokenOrder = restored.templatePreset.defaultTokenOrder }
            conversionSelection = restored
        }

        wirePlaybackBindings()
        configureNowPlaying()
        applyVolumeToEngines()

        // Load playlists, CDs, and external devices
        self.playlists = playlistService.listPlaylists()
        self.mountedCDs = cdRipper.detectAudioCDs()
        self.mountedDevices = detectSavedDevices()

        if let outputUID = prefs.selectedOutputDeviceUID {
            playback.setOutputDeviceUID(outputUID)
        }

        setupAudioDeviceObserver()
        setupCDSpeedObserver()
        setupKeyboardShortcutsMonitor()
        setupLibraryOperationsObservers()
        setupVolumeObservers()
        setupEqualizerObserver()
        reloadEqualizerFromPrefs()

        refreshAvailableCrates()
        streams = streamStore.all()
        selectSource(.localAll)
        recomputeOfflineVolumes()
        recomputeMissingFiles()
        fetchMissingMetadata()
    }

    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func setupAudioDeviceObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerAudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let uid = notification.object as? String
            Task { @MainActor [weak self] in
                self?.playback.setOutputDeviceUID(uid)
            }
        }
    }

    private func setupCDSpeedObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerCDSpeedChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let speed = notification.object as? CDAnimationSpeed {
                Task { @MainActor [weak self] in
                    self?.cdAnimationSpeed = speed
                }
            }
        }
    }

    private func setupLibraryOperationsObservers() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerMoveLibrary"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.moveLibrary()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerConsolidateLibrary"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.consolidateLibrary()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerCratesFolderChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAvailableCrates()
                self?.selectSource(self?.currentSource ?? .localAll)
            }
        }
    }

    private func setupKeyboardShortcutsMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Bare arrows navigate the browser (↑/↓ select, ←/→ switch columns)
            // when the main window is focused and no text field is editing. Takes
            // precedence over the transport/volume shortcuts below, which remain on
            // ⌘-arrows via the menu.
            if self.handleBrowserArrowNav(event) { return nil }

            // Do not intercept shortcuts if user is typing in a text field (first responder is NSTextField)
            if let _ = self.activeTextField() {
                return event
            }

            let shortcuts = self.prefs.keyboardShortcuts
            let key = self.shortcutKeyForEvent(event)
            
            for (action, mappedKey) in shortcuts {
                let defaultVal = self.defaultShortcutKey(for: action)
                if (mappedKey.isEmpty && key == defaultVal) || (!mappedKey.isEmpty && key == mappedKey) {
                    self.executeShortcutAction(action)
                    return nil // Handled
                }
            }

            return event
        }
    }

    private func activeTextField() -> NSTextField? {
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder as? NSTextView,
              let delegate = responder.delegate as? NSTextField else {
            return nil
        }
        return delegate
    }

    private func shortcutKeyForEvent(_ event: NSEvent) -> String {
        if event.keyCode == 49 { return "Space" }
        if event.keyCode == 124 { return "Right Arrow" }
        if event.keyCode == 123 { return "Left Arrow" }
        if event.keyCode == 126 { return "Up Arrow" }
        if event.keyCode == 125 { return "Down Arrow" }
        return event.charactersIgnoringModifiers?.uppercased() ?? ""
    }

    private func defaultShortcutKey(for action: String) -> String {
        switch action {
        case "playPause": return "Space"
        case "next": return "Right Arrow"
        case "previous": return "Left Arrow"
        case "volumeUp": return "Up Arrow"
        case "volumeDown": return "Down Arrow"
        case "seekForward": return "F"
        case "seekBackward": return "B"
        default: return ""
        }
    }

    private func executeShortcutAction(_ action: String) {
        switch action {
        case "playPause": togglePlayPause()
        case "next": next()
        case "previous": previous()
        case "volumeUp": setVolume(playbackVolume + 0.05)
        case "volumeDown": setVolume(playbackVolume - 0.05)
        case "seekForward": forward8s()
        case "seekBackward": rewind8s()
        default: break
        }
    }

    // MARK: - Selection helpers

    var selectedArtist: Artist? {
        guard let id = selectedArtistID else { return index.artists.first }
        return index.artist(id: id) ?? index.artists.first
    }

    var selectedAlbum: Album? {
        if let id = selectedAlbumID, let found = index.albumOrVersion(id: id) { return found }
        return selectedArtist?.albums.first
    }

    /// All artists, sorted by the artist-sort preference. Cached — recomputed
    /// only when the index or artist-sort preference changes, so the 60fps disc
    /// animation re-reads a stored array instead of re-sorting every frame.
    @Published private(set) var visibleArtists: [Artist] = []

    var visibleAlbums: [Album] {
        let base = selectedArtist?.albums ?? []
        return LibraryIndex.sortedAlbums(base, by: albumSortField, ascending: albumSortAscending)
    }

    var visibleTracks: [LoadedTrack] {
        let base = selectedAlbum?.tracks ?? []
        return LibraryIndex.sortedTracks(base, by: trackSortField, ascending: trackSortAscending)
    }

    /// Every album across all artists, sorted by the album-sort preference.
    /// Drives the "Album · Track" browser layout. Cached — see
    /// recomputeSortedCollections().
    @Published private(set) var allAlbumsSorted: [Album] = []

    /// Every track in the source, sorted by the track-sort preference. Drives
    /// the flat "Track" browser layout. Cached — see recomputeSortedCollections().
    @Published private(set) var flatTracksSorted: [LoadedTrack] = []

    /// Recompute the cached whole-library sorted collections. Cheap and rare —
    /// runs only on index or sort-preference changes, never during a render
    /// pass. At 14k tracks the locale-aware sort is far too expensive to repeat
    /// per frame, which the spinning-disc animation would otherwise trigger.
    private func recomputeSortedCollections() {
        visibleArtists = LibraryIndex.sortedArtists(index.artists, by: artistSortField, ascending: artistSortAscending)
        allAlbumsSorted = LibraryIndex.sortedAlbums(index.allAlbums, by: albumSortField, ascending: albumSortAscending)
        flatTracksSorted = LibraryIndex.sortedTracks(index.allTracks, by: trackSortField, ascending: trackSortAscending)
    }

    var selectedTrack: LoadedTrack? {
        guard let id = selectedTrackID else { return visibleTracks.first }
        return visibleTracks.first(where: { $0.track.id == id }) ?? visibleTracks.first
    }

    var nowPlayingTrack: LoadedTrack? {
        guard let i = playbackCurrentIndex, i >= 0, i < playbackQueue.count else { return nil }
        return playbackQueue[i]
    }

    /// Select the playing track's album so the browser and inspector both jump to
    /// it. No-op when the playing track isn't in the current source's index — the
    /// queue can outlive a source switch, and silently swapping crates under the
    /// user is worse than doing nothing.
    func revealNowPlaying() {
        guard let playing = nowPlayingTrack else { return }
        let trackID = playing.track.id
        // The browsable owner: the album actually present in index.allAlbums. For a
        // grouped release that's the parent group album (member pressings live only
        // inside its `.versions`, so a member's id would match no gallery tile and no
        // list row). album(containing:) returns the member — right for the artwork
        // callers, wrong for browser selection — so resolve the parent here instead.
        var owner: Album?
        outer: for artist in index.artists {
            for album in artist.albums {
                if album.tracks.contains(where: { $0.track.id == trackID })
                    || (album.versions ?? []).contains(where: { $0.tracks.contains { $0.track.id == trackID } }) {
                    owner = album
                    break outer
                }
            }
        }
        guard let album = owner else { return }
        clearMultiSelection()
        selectedArtistID = album.artistID
        selectedAlbumID = album.id
        selectedTrackID = trackID
    }

    /// The browsed album containing a track (linear scan over the current
    /// index). Shared by the spinning disc and the mini player so both resolve
    /// cover files (booklet/folder art) the same way.
    func album(containing trackID: UUID) -> Album? {
        for artist in index.artists {
            for album in artist.albums {
                if album.tracks.contains(where: { $0.track.id == trackID }) {
                    return album
                }
                for version in album.versions ?? [] where version.tracks.contains(where: { $0.track.id == trackID }) {
                    return version
                }
            }
        }
        return nil
    }

    // MARK: - Source Management

    var isLocalSource: Bool {
        switch currentSource {
        case .localAll, .localCrate: return true
        default: return false
        }
    }

    /// Build a browsable index, folding in the user's album version groups. All
    /// index construction goes through here so grouping applies uniformly. Grouping
    /// only takes effect where ≥2 member pressings are present, so non-local indexes
    /// (CD/playlist/remote) are unaffected — their keys never match local groups.
    /// Reused across rebuilds so `LibraryIndex.build` doesn't re-stat every file
    /// and re-scan every album folder on each edit/source switch. Cleared after
    /// in-place artwork edits (see applyImportedArtwork); move/import changes
    /// self-invalidate because the cache is keyed by file/folder path.
    /// Internal, not private: the ART inspector invalidates the folder it just
    /// wrote a manifest into, the same way applyImportedArtwork does.
    let indexDiskCache = LibraryIndexDiskCache()

    func buildIndex(_ tracks: [LoadedTrack]) -> LibraryIndex {
        LibraryIndex.build(from: tracks, groups: albumGroupStore.all(), diskCache: indexDiskCache)
    }

    func selectSource(_ source: LibrarySource) {
        // Browsing never stops the stream — only playing a local track does
        // (see playTrack). The stream keeps playing while you browse the library.
        //
        // A genuine source switch lands the browser at the top; re-selecting the
        // *same* source is an in-place refresh (after a tag edit, cleanup, delete,
        // artwork import, …) and must keep the user's place — the selectedArtist/
        // Album/Track computed vars already fall back to first if an anchor id no
        // longer resolves in the rebuilt index.
        let sourceChanged = source != currentSource
        currentSource = source
        switch source {
        case .localAll:
            var all: [LoadedTrack] = []
            for name in availableCrates {
                all.append(contentsOf: loadCrateTracks(name: name))
            }
            let merged = LibraryViewModel.deduplicate(tracks: all)
            localIndex = buildIndex(merged)
            index = localIndex
        case .localCrate(let name):
            let tracks = loadCrateTracks(name: name)
            localIndex = buildIndex(tracks)
            index = localIndex
        case .prepCrate:
            prepCrateIndex = buildIndex(prepCrateTracks)
            index = prepCrateIndex
        case .remote:
            index = remoteIndex
            if remoteIndex.artists.isEmpty {
                connectSubsonic()
            }
        case .playlist(let name):
            selectPlaylist(name: name)
        case .cd(let path):
            selectCD(volumePath: path)
        case .device(let path):
            selectDevice(volumePath: path)
        case .radio(let category):
            // The browser renders RadioListView from `filteredStreams`, not `index`.
            radioCategoryFilter = category
            index = .empty
        }

        if case .radio = source {
            // Radio selection state is driven by selectedStreamID, not the library index.
            refreshCrateCounts()
            return
        }

        if sourceChanged {
            selectedArtistID = index.artists.first?.id
            selectedAlbumID = index.artists.first?.albums.first?.id
            selectedTrackID = index.artists.first?.albums.first?.tracks.first?.track.id
            selectedAlbumIDs = []
            selectedTrackIDs = []
        }

        refreshCrateCounts()
    }

    // MARK: - Folder loading

    func openFolderViaPanel() {
        _ = checkAndPromptForCratesFolder()

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

    func loadFolders(_ urls: [URL], isRestore: Bool = false) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        scanProgress = ScanProgress(folderName: urls.first?.lastPathComponent, filesProbed: 0, totalCandidates: nil, isRunning: true)
        // An explicit import jumps the OLED to Scan. Skip on launch restore so
        // we don't override the user's saved view every time the app opens.
        if !isRestore { oledView = .scan }
        playback.load(queue: [], startIndex: 0, autoPlay: false)
        playbackQueue = []

        scanTask = Task { [weak self] in
            guard let self else { return }
            var collected: [LoadedTrack] = []
            for url in urls {
                if Task.isCancelled { break }
                let scanned = await self.scanner.scanFolder(
                    url,
                    onProgress: self.scanProgressReporter(
                        generation: generation,
                        folderName: url.lastPathComponent,
                        baseProbed: collected.count
                    )
                )
                collected.append(contentsOf: scanned)
            }
            if Task.isCancelled { return }

            let merged = LibraryViewModel.deduplicate(tracks: collected)

            await MainActor.run {
                if !isRestore {
                    self.persistFolderBookmarks(urls)
                }
                self.handleImport(merged)
            }
        }
    }

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
        guard !resolvedURLs.isEmpty else { return }
        loadFolders(resolvedURLs, isRestore: true)
    }

    private func persistFolderBookmarks(_ urls: [URL]) {
        // Merge with the already-saved dig folders (dedup by path) so a new dig
        // adds to the restored Prep Crate on next launch instead of replacing it.
        var byPath: [String: Data] = [:]
        var order: [String] = []
        for data in prefs.savedLibraryFolderBookmarks {
            guard let resolved = PreferencesStore.resolveBookmark(data) else { continue }
            let path = resolved.url.standardizedFileURL.path
            if byPath[path] == nil { order.append(path) }
            byPath[path] = data
        }
        for url in urls {
            do {
                let bookmark = try PreferencesStore.makeBookmark(for: url)
                let path = url.standardizedFileURL.path
                if byPath[path] == nil { order.append(path) }
                byPath[path] = bookmark
            } catch {
                AppLog.library.warning("Could not bookmark \(url.path): \(String(describing: error))")
            }
        }
        // ponytail: keep the 20 most recent folders so launch restore stays bounded.
        prefs.savedLibraryFolderBookmarks = order.suffix(20).compactMap { byPath[$0] }
    }

    /// Builds the `onProgress` closure a scan hands to `LibraryScanService`:
    /// throttled to ~1% steps, hopped to the main actor, and generation-guarded
    /// so a superseded scan can't overwrite a newer one's numbers.
    nonisolated private func scanProgressReporter(
        generation: Int,
        folderName: String,
        baseProbed: Int
    ) -> @Sendable (Int, Int) -> Void {
        { [weak self] probed, total in
            let step = max(1, total / 100)
            guard probed % step == 0 || probed == total else { return }
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.scanProgress = ScanProgress(
                    folderName: folderName,
                    filesProbed: baseProbed + probed,
                    totalCandidates: baseProbed + total,
                    isRunning: true
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

    // MARK: - Subsonic / Navidrome integration

    func connectSubsonic() {
        guard let urlStr = prefs.subsonicURL, let user = prefs.subsonicUsername, let pass = prefs.subsonicPassword,
              !urlStr.isEmpty, !user.isEmpty, !pass.isEmpty else {
            return
        }

        let config = SubsonicConfig(url: urlStr, username: user, password: pass)
        oledView = .remoteSync
        scanProgress = ScanProgress(folderName: "Syncing Remote...", filesProbed: 0, totalCandidates: nil, isRunning: true)

        Task {
            do {
                let artists = try await subsonicClient.getArtists(config: config)
                var allTracks: [LoadedTrack] = []

                // Fetch top 30 artists to populate real tracks quickly
                let limit = min(artists.count, 30)
                for i in 0..<limit {
                    let art = artists[i]
                    let albums = try await subsonicClient.getArtist(id: art.id, config: config)
                    for alb in albums {
                        let subTracks = try await subsonicClient.getAlbum(id: alb.id, config: config)
                        for subTrack in subTracks {
                            guard let streamURL = subsonicClient.streamURL(forTrackID: subTrack.id, config: config) else {
                                continue
                            }

                            // Optional cover art mapping
                            var artwork: ArtworkAsset?
                            if let coverID = subTrack.coverArt,
                               let artURL = subsonicClient.coverArtURL(forCoverArtID: coverID, config: config) {
                                artwork = ArtworkAsset(source: .remote, hash: coverID, dimensions: ArtworkDimensions(width: 300, height: 300), data: Data())
                                // Pre-cache Remote artwork URL
                                self.artworkService.cacheRemoteArtworkURL(coverID, url: artURL)
                            }

                            let track = AudioTrack(
                                fileURL: streamURL,
                                title: subTrack.title,
                                artist: subTrack.artist,
                                album: subTrack.album,
                                durationSeconds: Double(subTrack.duration ?? 0),
                                formatName: subTrack.suffix?.uppercased(),
                                bitrateKbps: subTrack.bitRate,
                                sampleRateHz: subTrack.sampleRate,
                                year: alb.year,
                                trackNumber: subTrack.track,
                                artworkSource: artwork != nil ? .remote : .none,
                                artworkHash: artwork?.hash,
                                artworkDimensions: artwork?.dimensions
                            )
                            let metadata = ConversionMetadata(
                                title: subTrack.title,
                                artist: subTrack.artist,
                                album: subTrack.album,
                                trackNumber: subTrack.track,
                                year: alb.year,
                                artwork: artwork
                            )
                            allTracks.append(LoadedTrack(track: track, metadata: metadata))
                        }
                    }
                }

                let built = self.buildIndex(allTracks)
                await MainActor.run {
                    self.remoteIndex = built
                    if case .remote = self.currentSource {
                        self.index = built
                        self.selectedArtistID = built.artists.first?.id
                        self.selectedAlbumID = built.artists.first?.albums.first?.id
                        self.selectedTrackID = built.artists.first?.albums.first?.tracks.first?.track.id
                    }
                    self.oledView = .nowPlaying
                    self.scanProgress = .idle
                }
            } catch {
                await MainActor.run {
                    self.oledView = .nowPlaying
                    self.scanProgress = .idle
                    self.appAlert = .error(title: "Remote Sync Failed", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - CD Rip integration

    func refreshCDs() {
        mountedCDs = cdRipper.detectAudioCDs()
    }

    // MARK: - External devices

    /// Re-detect mounted removable devices. Wired to the volume mount/unmount
    /// observers (see `setupVolumeObservers`) plus init + sidebar appear.
    func refreshDevices() {
        let detected = detectSavedDevices()
        backfillVolumeUUIDs(for: detected)
        if detected != mountedDevices { mountedDevices = detected }
        // Drop cached scans for devices that are no longer mounted.
        let mountedPaths = Set(detected.map { $0.volumeURL.path })
        deviceIndexCache = deviceIndexCache.filter { mountedPaths.contains($0.key) }
        // If the device we're browsing was unplugged, fall back to the library.
        if case .device(let path) = currentSource,
           !detected.contains(where: { $0.volumeURL.path == path }) {
            selectSource(.localAll)
        }
    }

    /// Mounted removable volumes that match a device profile saved in Settings
    /// (by configured root path, else by name), minus audio CDs. Random drives
    /// and DMG mounts never reach Sources — only devices the user has added.
    private func detectSavedDevices() -> [MountedDevice] {
        let cdPaths = Set(mountedCDs.map { $0.volumeURL.path })
        return deviceDetector.detectDevices().filter { dev in
            !cdPaths.contains(dev.volumeURL.path) && deviceProfile(for: dev) != nil
        }
    }

    /// The saved Settings profile a mounted device belongs to (by volume UUID when
    /// known, else configured root path, else name), or nil for an unknown volume.
    func deviceProfile(for device: MountedDevice) -> ExternalDeviceProfile? {
        ExternalDeviceProfile.match(device, in: prefs.savedExternalDeviceProfiles)
    }

    /// Self-heal for profiles saved before volume UUIDs were captured: stamp a
    /// mounted volume's UUID onto its matched profile the first time we see them
    /// together, so a *different* device that merely shares the mount path or name
    /// stops matching. ponytail: first device to connect wins the stamp — correct
    /// for the usual one-profile-one-device case; re-add the profile to re-point it.
    private func backfillVolumeUUIDs(for devices: [MountedDevice]) {
        for device in devices {
            guard let uuid = device.volumeUUID,
                  var profile = deviceProfile(for: device),
                  profile.volumeUUID == nil else { continue }
            profile.volumeUUID = uuid
            profile.updatedAt = Date()
            prefs.upsertExternalDeviceProfile(profile)
        }
    }

    /// Browse a mounted device. The first visit scans its audio files (async — a
    /// Rockbox iPod over USB can hold thousands of files; ponytail: full-volume
    /// recursive scan, scope to a music subfolder if it ever feels slow) and
    /// caches the result; later visits reuse the cache. RESCAN forces a fresh
    /// walk via `forceRescan`.
    private func selectDevice(volumePath: String, forceRescan: Bool = false) {
        guard let device = mountedDevices.first(where: { $0.volumeURL.path == volumePath }) else {
            index = .empty
            return
        }
        let key = device.catalogKey
        if !forceRescan, let cached = deviceIndexCache[volumePath] {
            oledView = .scan   // surface the path bar without re-walking the disk
            adoptDeviceIndex(cached)
            return
        }
        // Persisted catalog from a previous scan/launch → open instantly, no walk.
        if !forceRescan, let saved = deviceCatalogStore.load(key: key) {
            let built = buildIndex(saved)
            deviceIndexCache[volumePath] = built
            oledView = .scan
            adoptDeviceIndex(built)
            return
        }
        index = .empty
        scanProgress = ScanProgress(folderName: device.name, filesProbed: 0, totalCandidates: nil, isRunning: true)
        oledView = .scan
        let root = device.volumeURL
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let scanned = await self.scanner.scanFolder(root)
            if Task.isCancelled { return }
            // Persist the catalog off-main so a big iPod doesn't hitch the UI.
            Task.detached(priority: .utility) { DeviceCatalogStore().save(scanned, key: key) }
            await MainActor.run {
                let built = self.buildIndex(scanned)
                self.deviceIndexCache[volumePath] = built
                self.scanProgress = .idle
                // Only adopt the result if the user is still on this device.
                guard case .device(let current) = self.currentSource, current == volumePath else { return }
                self.adoptDeviceIndex(built)
            }
        }
    }

    private func adoptDeviceIndex(_ built: LibraryIndex) {
        index = built
        selectedArtistID = built.artists.first?.id
        selectedAlbumID = built.artists.first?.albums.first?.id
        selectedTrackID = built.artists.first?.albums.first?.tracks.first?.track.id
    }

    /// Present the device-transfer sheet (the same one as ⌘⇧T), so the Sources
    /// "Transfer here" button is a discoverable way into the existing flow.
    func requestExternalDeviceTransfer() {
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerTransferToDevice"), object: nil)
    }

    private func selectCD(volumePath: String) {
        guard let cd = mountedCDs.first(where: { $0.volumeURL.path == volumePath }) else { return }
        let tracks = cd.tracks.map { track -> LoadedTrack in
            let audioTrack = AudioTrack(
                fileURL: track.fileURL,
                title: track.title,
                artist: "Audio CD",
                album: cd.name,
                durationSeconds: 0, // AVURLAsset will compute it
                formatName: "AIFF",
                trackNumber: track.trackNumber
            )
            let metadata = ConversionMetadata(
                title: track.title,
                artist: "Audio CD",
                album: cd.name,
                trackNumber: track.trackNumber
            )
            return LoadedTrack(track: audioTrack, metadata: metadata)
        }
        cdIndex = buildIndex(tracks)
        index = cdIndex
    }

    func ripCD(info: AudioCDInfo) {
        guard let dest = currentConversionDestinationURL else {
            self.appAlert = .error(title: "No Destination Set", message: "Choose where converted files go in Preferences.")
            return
        }

        oledView = .cdRip
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: info.tracks.count, currentFilename: nil, isRunning: true)

        let targetPreset = conversionSelection.outputFormat
        let preset = ConversionPreset(
            id: "cd_rip",
            name: "CD Rip",
            outputFormat: targetPreset,
            bitrateKbps: conversionSelection.bitrate,
            sampleRateHz: conversionSelection.sampleRate,
            channels: 2
        )

        Task {
            do {
                let service = try ConversionService(presets: [preset])
                var jobs: [ConversionJob] = []

                for track in info.tracks {
                    let filename = "Track \(track.trackNumber).\(preset.outputExtension)"
                    let targetURL = dest.appendingPathComponent(info.name).appendingPathComponent(filename)
                    let metadata = ConversionMetadata(
                        title: track.title,
                        artist: "Audio CD",
                        album: info.name,
                        trackNumber: track.trackNumber
                    )
                    jobs.append(ConversionJob(sourceURL: track.fileURL, destinationURL: targetURL, metadata: metadata))
                }

                _ = service.enqueue(jobs, preset: preset)

                let results = await Task.detached {
                    return service.runQueuedJobs(maxConcurrentWorkers: 1)
                }.value

                await MainActor.run {
                    self.oledView = .nowPlaying
                    self.conversionProgress = .idle
                    let fails = results.filter { $0.status == .failed }
                    if fails.isEmpty {
                        self.appAlert = .error(title: "CD Ripped!", message: "Successfully ripped \(info.tracks.count) tracks.")
                        self.loadFolders([dest]) // Automatically scan destination
                    } else {
                        self.appAlert = .error(title: "Rip Failed", message: "Failed to rip \(fails.count) tracks.")
                    }
                }
            } catch {
                await MainActor.run {
                    self.oledView = .nowPlaying
                    self.conversionProgress = .idle
                    self.appAlert = .error(title: "Rip Error", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Playlist Actions

    func createPlaylist(name: String) {
        let playlist = Playlist(name: name, trackURLs: [])
        try? playlistService.savePlaylist(playlist)
        playlists = playlistService.listPlaylists()
    }

    func deletePlaylist(name: String) {
        try? playlistService.deletePlaylist(name: name)
        playlists = playlistService.listPlaylists()
        selectSource(.localAll)
    }

    private func selectPlaylist(name: String) {
        guard let pl = playlists.first(where: { $0.name == name }) else { return }
        
        // Match M3U URLs to loaded local tracks, fallback to creating temporary audio tracks
        let tracks = pl.trackURLs.map { url -> LoadedTrack in
            if let matched = localIndex.allTracks.first(where: { $0.track.fileURL.standardizedFileURL.path == url.standardizedFileURL.path }) {
                return matched
            }
            let audioTrack = AudioTrack(fileURL: url, title: url.deletingPathExtension().lastPathComponent)
            return LoadedTrack(track: audioTrack, metadata: ConversionMetadata(title: audioTrack.title))
        }

        playlistIndex = buildIndex(tracks)
        index = playlistIndex
    }

    // MARK: - Metadata Editor Actions

    /// Flash a short confirmation on the OLED rail. Repeated calls (batch tag
    /// saves) just restart the clear timer.
    func showOLEDNotice(_ text: String) {
        oledNotice = text
        oledNoticeClearTask?.cancel()
        oledNoticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.oledNotice = nil
        }
    }

    func updateTrackMetadata(_ track: LoadedTrack, newMetadata: ConversionMetadata) {
        guard let editor = metadataEditor else { return }

        let updatedTrack = AudioTrack(
            id: track.track.id,
            fileURL: track.track.fileURL,
            title: newMetadata.title ?? track.track.title,
            artist: newMetadata.artist ?? track.track.artist,
            album: newMetadata.album ?? track.track.album,
            durationSeconds: track.track.durationSeconds,
            formatName: track.track.formatName,
            bitrateKbps: track.track.bitrateKbps,
            sampleRateHz: track.track.sampleRateHz,
            year: newMetadata.year ?? track.track.year,
            trackNumber: newMetadata.trackNumber ?? track.track.trackNumber,
            // Surface track/disc totals too — the browser groups and sorts discs
            // off the AudioTrack's own fields, so omitting these silently reverted
            // an edited disc number to nil (disc 1) even though the tag was saved.
            trackTotal: newMetadata.trackTotal ?? track.track.trackTotal,
            discNumber: newMetadata.discNumber ?? track.track.discNumber,
            discTotal: newMetadata.discTotal ?? track.track.discTotal,
            artworkSource: track.track.artworkSource,
            artworkHash: track.track.artworkHash,
            artworkDimensions: track.track.artworkDimensions
        )
        let updatedTrackLoaded = LoadedTrack(track: updatedTrack, metadata: newMetadata,
                                             recordMarkers: track.recordMarkers)
        let sourceURL = track.track.fileURL
        // Keep-organised decision made up front so the background hop below
        // doesn't need to touch main-actor state.
        let organiseFolder: URL? = {
            guard prefs.keepLibraryOrganised, let libURL = managedLibraryFolderURL,
                  sourceURL.path.hasPrefix(libURL.path) else { return nil }
            return libURL
        }()
        let organiseByAlbumArtist = prefs.organiseByAlbumArtist

        showOLEDNotice("SAVING…")
        // Writing tags = ffmpeg rewriting the whole file — quick, but not
        // instant on a big FLAC, so it must not block the main actor. Serial
        // queue so batch saves stream one ffmpeg at a time, not a burst.
        Self.tagWriteQueue.async { [weak self] in
            do {
                try editor.writeMetadata(to: sourceURL, metadata: newMetadata)
            } catch {
                DispatchQueue.main.async {
                    self?.appAlert = .error(title: "Save Failed", message: error.localizedDescription)
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let libURL = organiseFolder else {
                    self.updateTrackURLInIndex(oldURL: sourceURL, newTrack: updatedTrackLoaded)
                    self.showOLEDNotice("TAGS SAVED")
                    return
                }
                Task {
                    let organizer = LibraryOrganizerService()
                    do {
                        let organized = try await organizer.organize(
                            tracks: [updatedTrackLoaded],
                            destinationFolder: libURL,
                            copyOnly: false, // Move the file to keep organized
                            organiseByAlbumArtist: organiseByAlbumArtist
                        )

                        if let movedTrack = organized.first {
                            await MainActor.run {
                                self.updateTrackURLInIndex(oldURL: sourceURL, newTrack: movedTrack)
                                self.showOLEDNotice("SAVED · FILE RELOCATED")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.updateTrackURLInIndex(oldURL: sourceURL, newTrack: updatedTrackLoaded)
                            self.appAlert = .error(title: "Save Alert", message: "Metadata written but file relocation failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Tag writes run here: off the main actor, one at a time.
    private static let tagWriteQueue = DispatchQueue(label: "com.cratedigger.tag-write", qos: .userInitiated)

    // MARK: - Library Cleanup & Duplicates Actions

    func scanForCleanup() {
        guard !isCleanupScanning else {
            pendingCleanupRescan = true
            return
        }
        isCleanupScanning = true
        let activity = beginActivity("Scanning library for cleanup…")
        let snapshot = localIndex
        let mode = duplicateScanMode
        let ignored = Set(PreferencesStore.shared.duplicateIgnoreSignatures)

        Task.detached(priority: .userInitiated) {
            let cleanup = LibraryCleanupService()
            let dead = cleanup.findDeadTracks(in: snapshot)
            let dups = cleanup.findDuplicates(in: snapshot, mode: mode, ignoring: ignored)
            await MainActor.run {
                // Don't flag tracks on a disconnected drive as "dead" — the files
                // aren't gone, the volume is just unplugged, and purging their
                // references would wreck an external library that's merely offline.
                self.deadTracks = dead.filter { self.offlineVolumeName(for: $0.track.fileURL) == nil }
                self.duplicateGroups = dups
                self.recomputeMissingFiles()
                self.isCleanupScanning = false
                self.endActivity(activity)
                if self.pendingCleanupRescan {
                    self.pendingCleanupRescan = false
                    self.scanForCleanup()
                }
            }
        }
    }

    func ignoreDuplicateGroup(_ group: DuplicateGroup) {
        let sig = LibraryCleanupService.signature(for: group)
        var sigs = PreferencesStore.shared.duplicateIgnoreSignatures
        if !sigs.contains(sig) { sigs.append(sig) }
        PreferencesStore.shared.duplicateIgnoreSignatures = sigs
        duplicateGroups.removeAll { $0.id == group.id }
    }

    func deleteDeadTracks() {
        let cleanup = LibraryCleanupService()
        do {
            try cleanup.deleteTracks(deadTracks, useTrash: false)
            purgeTracksFromLibraryState(paths: Set(deadTracks.map { $0.track.fileURL.standardizedFileURL.path }))
            deadTracks = []
            appAlert = .error(title: "Cleared", message: "Removed reference to dead tracks.")
        } catch {
            appAlert = .error(title: "Removal Failed", message: error.localizedDescription)
        }
    }

    /// Trash exactly the reviewed selection. Crates that referenced a trashed
    /// file whose group keeps a better copy are repointed to the kept copy —
    /// cleanup must not silently shrink a DJ's crates.
    func resolveDuplicates(selected: [LoadedTrack]) {
        guard !selected.isEmpty else { return }
        let selectedPaths = Set(selected.map { $0.track.fileURL.standardizedFileURL.path })

        // Keeper per group = best-ranked survivor (members are best-first).
        var repoint: [String: LoadedTrack] = [:]
        for group in duplicateGroups {
            let members = [group.bestTrack] + group.worstTracks
            let survivors = members.filter {
                !selectedPaths.contains($0.track.fileURL.standardizedFileURL.path)
            }
            guard let keeper = survivors.first else { continue }
            for member in members
            where selectedPaths.contains(member.track.fileURL.standardizedFileURL.path) {
                repoint[member.track.fileURL.standardizedFileURL.path] = keeper
            }
        }

        do {
            try LibraryCleanupService().deleteTracks(selected, useTrash: true)
            repointCrateReferences(repoint)
            purgeTracksFromLibraryState(paths: selectedPaths)
            scanForCleanup()
            let repointNote = repoint.isEmpty ? "" : " Crate entries now point at the kept copies."
            appAlert = .info(title: "Duplicates Cleared",
                             message: "\(selected.count) file\(selected.count == 1 ? "" : "s") moved to Trash.\(repointNote)")
        } catch {
            appAlert = .error(title: "Clear Failed", message: error.localizedDescription)
            scanForCleanup()
        }
    }

    /// Swap trashed paths for their keepers inside every crate + the prep
    /// crate, deduping by path (a crate holding both copies must end with one
    /// keeper entry, not two). Runs BEFORE purge, which then only strips
    /// references that had no surviving groupmate.
    private func repointCrateReferences(_ repoint: [String: LoadedTrack]) {
        guard !repoint.isEmpty else { return }

        func rewrite(_ tracks: [LoadedTrack]) -> [LoadedTrack]? {
            var seen = Set<String>()
            var changed = false
            var result: [LoadedTrack] = []
            for entry in tracks {
                let path = entry.track.fileURL.standardizedFileURL.path
                let mapped = repoint[path] ?? entry
                if repoint[path] != nil { changed = true }
                let mappedPath = mapped.track.fileURL.standardizedFileURL.path
                guard seen.insert(mappedPath).inserted else { changed = true; continue }
                result.append(mapped)
            }
            return changed ? result : nil
        }

        for crateName in availableCrates {
            if let rewritten = rewrite(loadCrateTracks(name: crateName)) {
                saveCrateTracks(rewritten, name: crateName, persistStore: false)
            }
        }
        if let rewritten = rewrite(prepCrateTracks) {
            prepCrateTracks = rewritten
        }
    }

    func refreshLibrary() {
        // RESCAN on a device re-walks that volume (the only time we re-scan it)
        // and refreshes its saved catalog.
        if case .device(let path) = currentSource {
            deviceIndexCache[path] = nil
            if let device = mountedDevices.first(where: { $0.volumeURL.path == path }) {
                deviceCatalogStore.remove(key: device.catalogKey)
            }
            selectDevice(volumePath: path, forceRescan: true)
            return
        }
        let newIndex = buildIndex(localIndex.allTracks)
        localIndex = newIndex
        if isLocalSource {
            index = localIndex
        }
    }

    func exportDuplicates(best: Bool, to destination: URL) {
        let cleanup = LibraryCleanupService()
        let tracksToCopy = duplicateGroups.map { best ? $0.bestTrack : $0.worstTracks.first! }
        do {
            try cleanup.copyTracks(tracksToCopy, to: destination)
            appAlert = .error(title: "Exported", message: "Exported duplicates to folder.")
        } catch {
            appAlert = .error(title: "Export Failed", message: error.localizedDescription)
        }
    }

    func automaticallyReorganizeLibrary() {
        guard let dest = currentConversionDestinationURL else {
            self.appAlert = .error(title: "No Destination Set", message: "Configure default output folder in Preferences.")
            return
        }
        let organizer = LibraryOrganizerService()
        Task {
            do {
                try await organizer.organize(tracks: localIndex.allTracks, destinationFolder: dest, copyOnly: false)
                self.loadFolders([dest])
            } catch {
                self.appAlert = .error(title: "Reorganization Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Playback actions

    func playTrack(id: UUID) {
        // Library playback and stream playback are mutually exclusive.
        stopRadio()
        let queue = currentAlbumQueue()
        guard let startIndex = queue.firstIndex(where: { $0.track.id == id }) else { return }
        // Fail fast with an actionable prompt if the file is missing/offline,
        // rather than a dead-end playback error.
        if presentIfFileMissing(queue[startIndex]) { return }
        // Starting a track jumps the OLED to Now Playing.
        oledView = .nowPlaying
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
        // A stream is the active playback (even if browsing the library): route
        // play/pause to the radio engine.
        if isStreamActive {
            if playbackState == .playing { radioEngine?.pause() } else { radioEngine?.resume() }
            return
        }
        if isRadioMode, let stream = selectedStream {
            // Browsing radio with nothing playing yet: start the selected stream.
            _ = stream
            playSelectedStream()
            return
        }
        if case .idle = playbackState, let track = visibleTracks.first {
            playTrack(id: track.track.id)
            return
        }
        playback.togglePlayPause()
    }

    func next() {
        // Step streams when one is playing or while browsing radio.
        if isStreamActive || isRadioMode { selectAdjacentStream(offset: 1); return }
        // Divided record: step between its tracks before leaving the file.
        if recordSeekToNextTrack() { return }
        playback.next()
    }
    func previous() {
        if isStreamActive || isRadioMode { selectAdjacentStream(offset: -1); return }
        if recordSeekToPreviousTrack() { return }
        playback.previous()
    }
    func rewind8s()  {
        if isStreamActive { radioEngine?.seek(toSeconds: max(0, playbackCurrentTime - 8)); return }
        playback.seek(toSeconds: max(0, playbackCurrentTime - 8))
    }
    func forward8s() {
        if isStreamActive { radioEngine?.seek(toSeconds: playbackCurrentTime + 8); return }
        playback.seek(toSeconds: min(playbackDuration, playbackCurrentTime + 8))
    }

    /// Seek to a 0...1 fraction of the current track (footer POSITION dial).
    func seek(toFraction fraction: Double) {
        if isStreamActive {
            // Live streams can't seek; VOD seeks against the known duration.
            guard let stream = selectedStream, !stream.isLive, playbackDuration > 0 else { return }
            radioEngine?.seek(toSeconds: min(max(fraction, 0), 1) * playbackDuration)
            return
        }
        guard playbackDuration > 0 else { return }
        playback.seek(toSeconds: min(max(fraction, 0), 1) * playbackDuration)
    }

    private func selectAdjacentStream(offset: Int) {
        let list = filteredStreams
        guard !list.isEmpty, let id = selectedStreamID,
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let next = (idx + offset + list.count) % list.count
        selectStream(id: list[next].id)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        playbackVolume = clamped
    }

    /// Latest real 0...1 VU levels (L/R) from the playback engine's audio tap.
    /// The footer meter polls this while playing.
    func currentPlaybackLevels() -> (left: Double, right: Double) {
        playback.currentLevels()
    }

    func currentPlaybackSpectrum() -> [Double] {
        playback.currentSpectrum()
    }

    // MARK: - Conversion entry

    func makeInitialConversionSelection() -> ConversionOptionsSelection {
        return conversionSelection
    }

    func toggleShuffle() { shuffleEnabled.toggle() }

    // MARK: - Conversion patch-bay queue stats

    var conversionQueueTracks: [LoadedTrack] {
        if let pending = pendingDeviceConversion { return pending.tracks }
        return tracksForBatchScope(conversionSelection.batchScope)
    }

    var conversionQueueDurationSeconds: Double {
        conversionQueueTracks.reduce(0) { $0 + $1.track.durationSeconds }
    }

    var conversionEstimatedOutputBytes: Int64 {
        let bitrate = conversionSelection.bitrate ?? 192
        let effective = isLosslessSelectedFormat ? bitrate * 5 : bitrate
        return Int64(conversionQueueDurationSeconds * Double(effective) * 1000.0 / 8.0)
    }

    var isLosslessSelectedFormat: Bool { conversionSelection.outputFormat.isLossless }

    var conversionDestinationDisplayPath: String {
        if let pending = pendingDeviceConversion {
            return "▶ \(pending.deviceName): " + Self.tildeShortened(pending.destinationRoot.path) + "/"
        }
        guard let url = currentConversionDestinationURL else {
            return "~/Music/CrateDigger Library/"
        }
        return Self.tildeShortened(url.path) + "/"
    }

    var currentConversionDestinationURL: URL? {
        if let pending = pendingDeviceConversion { return pending.destinationRoot }
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
            objectWillChange.send()
        }
    }

    /// Host for presenting sheets/panels. Prefers the key window but falls back to
    /// the main window — `keyWindow` can be nil right after a floating panel (e.g.
    /// the artwork viewer, a borderless window with no `contentViewController`)
    /// closes, which would otherwise silently no-op Convert / Transfer.
    var presentationHostViewController: NSViewController? {
        NSApp.keyWindow?.contentViewController ?? NSApp.mainWindow?.contentViewController
    }

    func triggerConversionFromPatchBay() {
        guard let host = presentationHostViewController else {
            AppLog.conversion.error("Convert pressed but no host window available")
            return
        }
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

    func applyFetchedArtwork(_ asset: ArtworkAsset, toAlbumID albumID: String) {
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
            return LoadedTrack(track: newTrack, metadata: newMetadata, recordMarkers: loaded.recordMarkers)
        }

        index = buildIndex(updatedTracks)
    }

    func downloadAndImportArtwork(
        images: [(url: URL, role: ArtworkRole, suggestedFilename: String, discNumber: Int?)],
        for album: Album
    ) async {
        let activity = beginActivity("Importing artwork…")
        defer { endActivity(activity) }
        guard let representative = album.tracks.first?.track.fileURL else { return }
        let albumFolder = representative.deletingLastPathComponent()
        
        let result = await Task.detached(priority: .userInitiated) { () -> (manifest: ArtworkManifest, ingestedAssets: [ArtworkAsset], coverFilename: String?, coverAsset: ArtworkAsset?) in
            var manifest = ArtworkManifest.load(from: albumFolder) ?? ArtworkManifest(mediaFormat: album.mediaFormat, roles: [:])
            var ingestedAssets: [ArtworkAsset] = []
            var coverFilename: String? = nil
            var newCoverAsset: ArtworkAsset? = nil
            
            // Parallel downloads
            typealias DownloadResult = (item: (url: URL, role: ArtworkRole, suggestedFilename: String, discNumber: Int?), data: Data)
            var downloadedData: [DownloadResult] = []
            
            do {
                try await withThrowingTaskGroup(of: DownloadResult.self) { group in
                    for item in images {
                        group.addTask {
                            let (data, _) = try await URLSession.shared.data(from: item.url)
                            return (item, data)
                        }
                    }
                    for try await res in group {
                        downloadedData.append(res)
                    }
                }
            } catch {
                AppLog.library.warning("Error downloading artwork in parallel: \(error.localizedDescription)")
            }
            
            for res in downloadedData {
                let item = res.item
                let data = res.data
                do {
                    guard let image = NSImage(data: data) else { continue }
                    
                    let fileURL = albumFolder.appendingPathComponent(item.suggestedFilename)
                    try data.write(to: fileURL, options: .atomic)
                    
                    let filename = fileURL.lastPathComponent
                    manifest.roles[filename] = item.role
                    if item.role == .disc, let disc = item.discNumber {
                        var discs = manifest.discNumbers ?? [:]
                        discs[filename] = disc
                        manifest.discNumbers = discs
                    }

                    let digest = SHA256.hash(data: data)
                    let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
                    
                    let asset = ArtworkAsset(
                        source: .remote,
                        hash: hashHex,
                        dimensions: ArtworkDimensions(width: Int(image.size.width), height: Int(image.size.height)),
                        data: data
                    )
                    ingestedAssets.append(asset)
                    
                    if item.role == .cover {
                        newCoverAsset = asset
                        coverFilename = filename
                    }
                } catch {
                    AppLog.library.warning("Failed to save or parse artwork: \(error.localizedDescription)")
                }
            }
            
            // The cover is written to the album folder as cover.jpg (above), which
            // is what CrateDigger displays everywhere, so we deliberately do NOT
            // rewrite every track file to embed it — that's hundreds of MB of I/O
            // on a lossless album for no in-app benefit. Conversion/transfer still
            // bake artwork into their *output* files when you export.

            // Save manifest
            if !ingestedAssets.isEmpty {
                try? manifest.save(to: albumFolder)
            }
            
            return (manifest, ingestedAssets, coverFilename, newCoverAsset)
        }.value

        // Back on MainActor: ingest to cache, rebuild indexes, notify, alert.
        applyImportedArtwork(
            ingestedAssets: result.ingestedAssets,
            coverAsset: result.coverAsset,
            for: album
        )
    }

    /// Attach image files chosen from disk to `album`. The files are copied into
    /// the album folder with role-based names; a `.cover` becomes the folder
    /// cover.jpg. Mirrors `downloadAndImportArtwork` but reads from the local disk.
    func attachLocalArtwork(
        fileURLs: [URL],
        role: ArtworkRole = .cover,
        for album: Album
    ) async {
        guard let representative = album.tracks.first?.track.fileURL else { return }
        let albumFolder = representative.deletingLastPathComponent()

        let result = await Task.detached(priority: .userInitiated) { () -> (ingestedAssets: [ArtworkAsset], coverAsset: ArtworkAsset?) in
            var manifest = ArtworkManifest.load(from: albumFolder) ?? ArtworkManifest(mediaFormat: album.mediaFormat, roles: [:])
            var ingestedAssets: [ArtworkAsset] = []
            var newCoverAsset: ArtworkAsset?

            for (offset, source) in fileURLs.enumerated() {
                do {
                    let data = try Data(contentsOf: source)
                    guard let image = NSImage(data: data) else { continue }

                    let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
                    let filename = Self.suggestedArtworkFilename(role: role, index: offset, ext: ext)
                    let fileURL = albumFolder.appendingPathComponent(filename)
                    try data.write(to: fileURL, options: .atomic)

                    manifest.roles[filename] = role

                    let digest = SHA256.hash(data: data)
                    let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
                    let asset = ArtworkAsset(
                        source: .embedded,
                        hash: hashHex,
                        dimensions: ArtworkDimensions(width: Int(image.size.width), height: Int(image.size.height)),
                        data: data
                    )
                    ingestedAssets.append(asset)

                    if role == .cover, newCoverAsset == nil {
                        newCoverAsset = asset
                    }
                } catch {
                    AppLog.library.warning("Failed to import local artwork: \(error.localizedDescription)")
                }
            }

            // No per-track embedding — the folder cover.jpg drives display; see
            // downloadAndImportArtwork.

            if !ingestedAssets.isEmpty {
                try? manifest.save(to: albumFolder)
            }

            return (ingestedAssets, newCoverAsset)
        }.value

        applyImportedArtwork(
            ingestedAssets: result.ingestedAssets,
            coverAsset: result.coverAsset,
            for: album
        )
    }

    /// Embed a small (≤600px, baseline/non-progressive JPEG) copy of the album's
    /// cover into every track, leaving the full-res cover.jpg in the folder intact.
    /// Runs detached and is NOT awaited, so the Save button returns instantly — the
    /// per-file rewrite (ffmpeg `-c copy`, dominated by the audio, not the image)
    /// happens quietly in the background.
    func embedCoverIntoTracksInBackground(for album: Album, deviceCompatible: Bool = true) {
        guard let folder = album.tracks.first?.track.fileURL.deletingLastPathComponent() else { return }
        // Prefer the manifest's .cover-roled file, else cover.jpg. `roles` is a
        // dictionary, so `.first(where:)` picked a different file run to run when
        // an album had more than one .cover — sort for a stable choice.
        let manifest = ArtworkManifest.load(from: folder)
        let coverName = manifest?.roles
            .filter { $0.value == .cover }
            .map(\.key)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first ?? "cover.jpg"
        let coverURL = folder.appendingPathComponent(coverName)
        guard FileManager.default.fileExists(atPath: coverURL.path) else { return }
        let tracks = album.tracks

        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: coverURL), let image = NSImage(data: data) else { return }
            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            let asset = ArtworkAsset(
                source: .folderImage, hash: hash,
                dimensions: ArtworkDimensions(width: Int(image.size.width), height: Int(image.size.height)),
                data: data
            )
            // Device-compatible: downscale to a 600px baseline JPEG (no PNG/progressive)
            // so Rockbox and legacy players can read the embedded art. Off = embed the
            // full-resolution original as-is (best for modern/desktop players).
            var embedURL = coverURL
            var tempURL: URL? = nil
            if deviceCompatible,
               let small = try? ArtworkService().prepareCompatibleArtwork(asset: asset, profile: .generic, maxDimension: 600),
               !small.data.isEmpty {
                let tmp = folder.appendingPathComponent(".cd_embed_cover.jpg")
                if (try? small.data.write(to: tmp, options: .atomic)) != nil { embedURL = tmp; tempURL = tmp }
            }
            let finalURL = embedURL
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for track in tracks {
                    if inFlight >= 4 { _ = await group.next(); inFlight -= 1 }
                    let fileURL = track.track.fileURL
                    group.addTask { try? MetadataEditorService().embedArtwork(to: fileURL, imageURL: finalURL) }
                    inFlight += 1
                }
            }
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        }
    }

    /// Shared tail for artwork imports (download or local upload): ingest the
    /// new assets, push the new cover into every index/cache the album lives in,
    /// refresh the now-playing disc, and report the album-wide scope.
    private func applyImportedArtwork(
        ingestedAssets: [ArtworkAsset],
        coverAsset: ArtworkAsset?,
        for album: Album
    ) {
        guard !ingestedAssets.isEmpty else { return }

        // This album's folder just gained cover.jpg / a manifest on disk.
        // Invalidate ONLY that folder's cached disk info instead of clearing the
        // whole cache — the rebuilds below then stay warm for every other folder
        // rather than cold-rebuilding the entire library on the main actor (which
        // is what froze the next album selection).
        if let albumFolder = album.tracks.first?.track.fileURL.deletingLastPathComponent().path {
            indexDiskCache.invalidate(albumFolderPath: albumFolder,
                                      filePaths: album.tracks.map { $0.track.fileURL.path })
        }

        for asset in ingestedAssets {
            self.artworkService.ingest(asset)
        }

        // Apply the new cover to the affected album's tracks wherever they
        // live — the current source index, the local crate cache, and the
        // prep crate — so the inspector poster, gallery, and (when playing)
        // the disc all refresh, not only when we're on a local source.
        let affectedTrackIDs = Set(album.tracks.map { $0.track.id })
        func applyArtwork(_ loaded: LoadedTrack) -> LoadedTrack {
            guard affectedTrackIDs.contains(loaded.track.id),
                  let coverAsset = coverAsset else { return loaded }
            var newTrack = loaded.track
            var newMetadata = loaded.metadata
            // Folder cover (cover.jpg), not embedded-in-file — matches what was
            // actually written and how a rescan would re-resolve it.
            newTrack.artworkSource = .folderImage
            newTrack.artworkHash = coverAsset.hash
            newTrack.artworkDimensions = coverAsset.dimensions
            newMetadata.artwork = coverAsset
            return LoadedTrack(track: newTrack, metadata: newMetadata, recordMarkers: loaded.recordMarkers)
        }

        self.localIndex = self.buildIndex(self.localIndex.allTracks.map(applyArtwork))
        self.prepCrateTracks = self.prepCrateTracks.map(applyArtwork)
        self.index = self.buildIndex(self.index.allTracks.map(applyArtwork))

        // Update SpinningRecordView (now playing) immediately.
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerArtworkImported"), object: nil)

        // No need to bounce selectedAlbumID: the rebuilt index gives selectedAlbum
        // a new artworkHash, and AlbumPoster's .task reloads on that hash change.

        // Tell the user the scope so it's clear cover art is album-wide.
        let trackCount = album.tracks.count
        if coverAsset != nil {
            self.appAlert = .info(
                title: "Cover art updated",
                message: "Saved as the cover for “\(album.title)” (\(trackCount) track\(trackCount == 1 ? "" : "s"))."
            )
        } else {
            let imageCount = ingestedAssets.count
            self.appAlert = .info(
                title: "Artwork imported",
                message: "Saved \(imageCount) image\(imageCount == 1 ? "" : "s") to the “\(album.title)” folder."
            )
        }
    }

    /// Rebuild every browsable index with new folder covers applied, in one pass.
    /// Lives here (not in +BatchArtwork) so it can write the private(set)
    /// index/localIndex; the batch fetch builds the map and calls this.
    func applyFolderCovers(_ assetByTrackID: [UUID: ArtworkAsset]) {
        guard !assetByTrackID.isEmpty else { return }
        func applyArtwork(_ loaded: LoadedTrack) -> LoadedTrack {
            guard let asset = assetByTrackID[loaded.track.id] else { return loaded }
            var newTrack = loaded.track
            var newMetadata = loaded.metadata
            newTrack.artworkSource = .folderImage
            newTrack.artworkHash = asset.hash
            newTrack.artworkDimensions = asset.dimensions
            newMetadata.artwork = asset
            return LoadedTrack(track: newTrack, metadata: newMetadata, recordMarkers: loaded.recordMarkers)
        }
        localIndex = buildIndex(localIndex.allTracks.map(applyArtwork))
        prepCrateTracks = prepCrateTracks.map(applyArtwork)
        index = buildIndex(index.allTracks.map(applyArtwork))
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerArtworkImported"), object: nil)
    }

    /// Role-based filename for an imported image (cover.jpg, back.jpg, …).
    nonisolated private static func suggestedArtworkFilename(role: ArtworkRole, index: Int, ext: String) -> String {
        switch role {
        case .cover:       return index == 0 ? "cover.\(ext)" : "cover_\(index + 1).\(ext)"
        case .altCover:    return index == 0 ? "cover_alt.\(ext)" : "cover_alt_\(index + 1).\(ext)"
        case .back:        return index == 0 ? "back.\(ext)" : "back_\(index + 1).\(ext)"
        case .disc:        return index == 0 ? "disc.\(ext)" : "disc_\(index + 1).\(ext)"
        case .inlay:       return index == 0 ? "inlay.\(ext)" : "inlay_\(index + 1).\(ext)"
        case .bookletPage: return String(format: "booklet_%02d.\(ext)", index + 1)
        case .ignore:      return "ignored_\(index + 1).\(ext)"
        case .auto:        return "artwork_\(index + 1).\(ext)"
        }
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

    // MARK: - Last.fm integration

    private func handlePlaybackStateChange(_ state: PlaybackState) {
        if state == .playing, let nowPlaying = nowPlayingTrack {
            // Track-start timestamp is set on index change; resetting it here
            // too would stamp scrobbles with the last *unpause* time instead.
            if playbackStartTimestamp == 0 {
                playbackStartTimestamp = Int(Date().timeIntervalSince1970)
            }

            // Check if we need to update "Now Playing" on Last.fm
            if let sessionKey = prefs.lastFmSessionKey, !sessionKey.isEmpty {
                Task {
                    _ = try? await lastFM.updateNowPlaying(
                        artist: nowPlaying.track.artist,
                        track: nowPlaying.track.title,
                        album: nowPlaying.track.album,
                        sessionKey: sessionKey
                    )
                }
            }
        }
    }

    private func checkScrobbleProgress(current: Double, duration: Double) {
        // Streams are never scrobbled.
        guard !isRadioMode else { return }

        // Accumulate real listened time from tick deltas. A seek produces a
        // jump far larger than the ~0.2s tick interval and adds nothing.
        if let last = lastScrobbleTickTime {
            let delta = current - last
            if delta > 0, delta < 2.0 { listenedSeconds += delta }
        }
        lastScrobbleTickTime = current

        guard let sessionKey = prefs.lastFmSessionKey, !sessionKey.isEmpty,
              let nowPlaying = nowPlayingTrack,
              lastScrobbledTrackID != nowPlaying.track.id else {
            return
        }

        // Last.fm guidelines: scrobble if played at least 4 minutes (240s) or half the duration, whichever is shorter, and played for at least 30s.
        let triggerTime = min(duration / 2.0, 240.0)
        if listenedSeconds >= triggerTime && listenedSeconds >= 30.0 {
            lastScrobbledTrackID = nowPlaying.track.id
            let artist = nowPlaying.track.artist
            let trackName = nowPlaying.track.title
            let album = nowPlaying.track.album
            let timestamp = playbackStartTimestamp
            
            Task {
                _ = try? await lastFM.scrobble(
                    artist: artist,
                    track: trackName,
                    album: album,
                    timestamp: timestamp,
                    sessionKey: sessionKey
                )
            }
        }
    }

    // MARK: - Bindings

    // MARK: - Radio engine state bridge
    //
    // The radio engines live in LibraryViewModel+Radio.swift and need to push
    // state onto these private(set) published properties. These helpers keep the
    // `private(set)` contract (only this type mutates playback state) while
    // letting the same-type extension drive it.

    func radioPublish(state: PlaybackState) { playbackState = state }

    func radioPublish(currentTime: Double, duration: Double) {
        playbackCurrentTime = currentTime
        playbackDuration = duration
    }

    private func wirePlaybackBindings() {
        playback.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.playbackState = state
                self?.handlePlaybackStateChange(state)
                self?.refreshNowPlayingInfo()
            }
        }
        playback.onCurrentIndexChange = { [weak self] index in
            Task { @MainActor in
                guard let self else { return }
                self.playbackCurrentIndex = index
                // New track (or repeat-one replay): reset the scrobble state so
                // a re-played track scrobbles again and listened time restarts.
                self.lastScrobbledTrackID = nil
                self.listenedSeconds = 0
                self.lastScrobbleTickTime = nil
                self.playbackStartTimestamp = Int(Date().timeIntervalSince1970)
                self.refreshNowPlayingInfo()
            }
        }
        playback.onTimeChange = { [weak self] current, duration in
            Task { @MainActor in
                self?.playbackCurrentTime = current
                self?.playbackDuration = duration
                self?.clearScrubPreviewIfSeekLanded(current)
                self?.applyPendingRecordSeekIfNeeded()
                self?.checkScrobbleProgress(current: current, duration: duration)
                self?.updateNowPlayingElapsed()
            }
        }
        playback.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                // If the failure is a missing/offline file (e.g. auto-advanced
                // into one), show the actionable locate/offline prompt instead
                // of the raw playback error.
                if let i = self.playbackCurrentIndex, i >= 0, i < self.playbackQueue.count,
                   self.presentIfFileMissing(self.playbackQueue[i]) {
                    return
                }
                self.appAlert = .error(
                    title: "Couldn't play this track",
                    message: message
                )
            }
        }
    }

    // MARK: - Managed Library Operations

    var managedLibraryFolderURL: URL? {
        guard let data = prefs.managedLibraryFolderBookmark else { return nil }
        return PreferencesStore.resolveBookmark(data)?.url
    }

    /// Finder drop anywhere on the window: scan the dropped files/folders and
    /// MERGE them into the Prep Crate. Unlike a dig (`handleImport`), a drop
    /// never replaces what's already staged.
    func importDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanProgress = ScanProgress(
            folderName: "Scanning dropped items…",
            filesProbed: 0, totalCandidates: nil, isRunning: true
        )
        Task { [weak self] in
            guard let self else { return }
            var collected: [LoadedTrack] = []
            for url in urls {
                let scanned = await self.scanner.scanFolder(
                    url,
                    onProgress: self.scanProgressReporter(
                        generation: generation,
                        folderName: url.lastPathComponent,
                        baseProbed: collected.count
                    )
                )
                collected.append(contentsOf: scanned)
            }
            await MainActor.run {
                guard !collected.isEmpty else {
                    self.scanProgress = .idle
                    self.appAlert = .error(
                        title: "Nothing to Import",
                        message: "No supported audio files were found in the dropped items."
                    )
                    return
                }
                self.ingestArtwork(from: collected)
                self.prepCrateTracks = LibraryViewModel.deduplicate(
                    tracks: self.prepCrateTracks + collected
                )
                self.selectSource(.prepCrate)
                self.scanProgress = ScanProgress(
                    folderName: nil,
                    filesProbed: collected.count,
                    totalCandidates: collected.count,
                    isRunning: false
                )
                self.scanForCleanup()
            }
        }
    }

    private func handleImport(_ tracks: [LoadedTrack]) {
        guard !tracks.isEmpty else {
            selectSource(.prepCrate)
            return
        }

        // Newly loaded folders MERGE into the Prep Crate — like a Finder drop,
        // a dig never replaces what's already staged. "Clear Prep Crate" is the
        // explicit way to empty it.
        ingestArtwork(from: tracks)
        prepCrateTracks = LibraryViewModel.deduplicate(tracks: prepCrateTracks + tracks)
        selectSource(.prepCrate)
        
        // Show a brief success alert in OLED display
        scanProgress = ScanProgress(
            folderName: nil,
            filesProbed: tracks.count,
            totalCandidates: tracks.count,
            isRunning: false
        )
        scanForCleanup()
    }

    /// Empty the Prep Crate — including the saved dig-folder bookmarks, or
    /// launch restore would just rescan them straight back into the crate.
    func clearPrepCrate() {
        prepCrateTracks = []
        prefs.savedLibraryFolderBookmarks = []
        if currentSource == .prepCrate {
            selectSource(.prepCrate)
        }
    }

    // MARK: - Crates Directory URL

    var cratesDirectoryURL: URL {
        let fm = FileManager.default
        if let data = prefs.cratesIndexFolderBookmark,
           let resolved = PreferencesStore.resolveBookmark(data)?.url {
            try? fm.createDirectory(at: resolved, withIntermediateDirectories: true)
            return resolved
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cratesDir = appSupport.appendingPathComponent("CrateDigger").appendingPathComponent("Crates")
        try? fm.createDirectory(at: cratesDir, withIntermediateDirectories: true)
        return cratesDir
    }

    func checkAndPromptForCratesFolder() -> Bool {
        if prefs.cratesIndexFolderBookmark == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "Choose default folder to save Crate Index Files (.cdlib)"
            panel.prompt = "Choose"
            panel.message = "Choose a default folder to store your Crate library index files. You can save/copy the actual music files to a separate location (like an external drive) later."
            
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    let data = try PreferencesStore.makeBookmark(for: url)
                    prefs.cratesIndexFolderBookmark = data
                    refreshAvailableCrates()
                    selectSource(currentSource)
                    return true
                } catch {
                    appAlert = .error(title: "Failed", message: "Could not set Crates folder: \(error.localizedDescription)")
                    return false
                }
            }
        }
        return true
    }

    func refreshAvailableCrates() {
        // The set of crates (or the active folder) is changing — drop the caches
        // so stale/renamed/removed crates can't survive. Rare, non-hot path.
        crateTracksCache.removeAll()
        trackStore = nil   // rebuilt lazily for the (possibly new) folder
        migrateLegacyCratesIfNeeded()
        let fm = FileManager.default
        let cratesDir = cratesDirectoryURL
        do {
            let contents = try fm.contentsOfDirectory(at: cratesDir, includingPropertiesForKeys: nil)
            let names = contents
                .filter { $0.pathExtension == "cdcrate" }
                .map { $0.deletingPathExtension().lastPathComponent }
            self.availableCrates = orderedCrates(names)

            // Auto-create Personal Crate if none exist
            if self.availableCrates.isEmpty {
                createCrate(name: Self.personalCrateName)
                return
            }

            if targetCrateName.isEmpty || !availableCrates.contains(targetCrateName) {
                if availableCrates.contains(Self.personalCrateName) {
                    targetCrateName = Self.personalCrateName
                } else if let first = availableCrates.first {
                    targetCrateName = first
                }
            }

            refreshCrateCounts()
        } catch {
            AppLog.library.warning("Failed to list crates: \(error.localizedDescription)")
        }
    }

    /// Orders crate names by the user's saved manual order (`prefs.savedCrateOrder`);
    /// any crate not in that list (new, renamed, or first run) is appended
    /// alphabetically. Saved names that no longer exist are dropped.
    private func orderedCrates(_ names: [String]) -> [String] {
        let present = Set(names)
        let ordered = prefs.savedCrateOrder.filter { present.contains($0) }
        let extras = names.filter { !ordered.contains($0) }.sorted()
        return ordered + extras
    }

    /// Manual drag-reorder from the Sources sidebar: move `name` to just before
    /// `beforeName` (or to the end when nil), then persist the order.
    func moveCrate(_ name: String, before beforeName: String?) {
        guard name != beforeName else { return }
        var order = availableCrates
        guard let from = order.firstIndex(of: name) else { return }
        order.remove(at: from)
        if let beforeName, let to = order.firstIndex(of: beforeName) {
            order.insert(name, at: to)
        } else {
            order.append(name)
        }
        availableCrates = order
        prefs.savedCrateOrder = order
    }

    func createCrate(name: String) {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else { return }
        saveCrateTracks([], name: safeName)
        refreshAvailableCrates()
    }

    func deleteCrate(name: String) {
        let fileURL = cratesDirectoryURL.appendingPathComponent("\(name).cdcrate")
        try? FileManager.default.removeItem(at: fileURL)
        refreshAvailableCrates()
        if case .localCrate(let currentName) = currentSource, currentName == name {
            selectSource(.localAll)
        } else {
            // Re-render
            selectSource(currentSource)
        }
    }

    /// Per-crate resolved track lists, keyed by crate name. Avoids re-reading a
    /// crate's membership file and re-resolving it against the shared TrackStore
    /// on repeated source switches. Cleared whenever the store is mutated
    /// (saveCrateTracks) or the folder changes (refreshAvailableCrates), so a
    /// track shared by several crates can't go stale after an edit.
    private var crateTracksCache: [String: [LoadedTrack]] = [:]

    /// The shared, deduplicated track store backing every crate. It lives inside
    /// the crates folder as `library.cdtracks`, so it's rebuilt when that folder
    /// changes. Crates only store membership (paths), not track copies.
    private var trackStore: TrackStore?
    private var trackStoreFolder: URL?

    private func currentTrackStore() -> TrackStore {
        let folder = cratesDirectoryURL
        if let store = trackStore, trackStoreFolder?.path == folder.path {
            return store
        }
        let store = TrackStore(fileURL: folder.appendingPathComponent("library.cdtracks"))
        trackStore = store
        trackStoreFolder = folder
        return store
    }

    /// A crate is a membership list of standardized file paths into the store.
    private func crateMembership(name: String) -> [String] {
        let url = cratesDirectoryURL.appendingPathComponent("\(name).cdcrate")
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths
    }

    func loadCrateTracks(name: String) -> [LoadedTrack] {
        if let cached = crateTracksCache[name] { return cached }
        let tracks = currentTrackStore().tracks(paths: crateMembership(name: name))
        crateTracksCache[name] = tracks
        return tracks
    }

    /// Move any artwork bytes embedded in a legacy `.cdlib` into the
    /// content-addressed `ArtworkStore`, so they survive the format change and
    /// cold-launch thumbnails resolve by hash. Write-once by hash. Used by the
    /// migration and by scan import.
    func ingestArtwork(from tracks: [LoadedTrack]) {
        for track in tracks {
            if let art = track.metadata.artwork, !art.data.isEmpty {
                artworkService.ingest(art)
            }
        }
    }

    /// Persist the shared track store, surfacing failures (full disk, unmounted
    /// volume) instead of silently dropping edits while the UI claims success.
    @discardableResult
    func persistTrackStore() -> Bool {
        do {
            try currentTrackStore().save()
            return true
        } catch {
            AppLog.library.error("Failed to save track store: \(error.localizedDescription)")
            appAlert = .error(title: "Library Save Failed",
                              message: "Could not write the library index: \(error.localizedDescription)")
            return false
        }
    }

    /// Save a crate's membership (and its tracks into the shared store).
    /// Pass `persistStore: false` inside multi-crate loops and call
    /// `persistTrackStore()` once after — the store write re-encodes every
    /// track it holds, so per-crate saves froze the UI for seconds at 14k tracks.
    @discardableResult
    func saveCrateTracks(_ tracks: [LoadedTrack], name: String, persistStore: Bool = true) -> Bool {
        let store = currentTrackStore()
        for track in tracks { store.upsert(track) }
        if persistStore, !persistTrackStore() { return false }
        let paths = tracks.map { TrackStore.key(for: $0.track.fileURL) }
        let url = cratesDirectoryURL.appendingPathComponent("\(name).cdcrate")
        do {
            let data = try JSONEncoder().encode(paths)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.library.error("Failed to save crate “\(name)”: \(error.localizedDescription)")
            appAlert = .error(title: "Crate Save Failed",
                              message: "Could not save “\(name)”: \(error.localizedDescription)")
            crateTracksCache.removeAll()
            return false
        }
        // The shared store changed; drop all per-crate caches so crates sharing
        // an edited track re-resolve fresh. Re-resolution is cheap (in-memory).
        crateTracksCache.removeAll()
        return true
    }

    /// One-time migration of legacy per-crate `.cdlib` files (full `LoadedTrack`s
    /// with embedded artwork) into the shared `TrackStore` + `.cdcrate` membership
    /// lists, moving artwork into the `ArtworkStore`. Originals are renamed to
    /// `.cdlib.bak` (not deleted) for recovery — delete the backups once you've
    /// confirmed the migration. Runs synchronously; a large library freezes the
    /// UI briefly on first launch.
    /// ponytail: synchronous decode of the whole library; make it async with a
    /// progress sheet if the first-launch pause is too long.
    private func migrateLegacyCratesIfNeeded() {
        let fm = FileManager.default
        let folder = cratesDirectoryURL
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let legacy = contents.filter { $0.pathExtension == "cdlib" }
        guard !legacy.isEmpty else { return }

        let store = currentTrackStore()
        for url in legacy {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let tracks = try? JSONDecoder().decode([LoadedTrack].self, from: data) else { continue }
            ingestArtwork(from: tracks)
            for track in tracks { store.upsert(track) }
            let paths = tracks.map { TrackStore.key(for: $0.track.fileURL) }
            let crateURL = folder.appendingPathComponent("\(name).cdcrate")
            if let membership = try? JSONEncoder().encode(paths) {
                try? membership.write(to: crateURL, options: .atomic)
            }
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        try? store.save()
        AppLog.library.info("Migrated \(legacy.count) legacy crate(s) into the shared track store.")
    }

    // MARK: - Drag & Drop Handling

    /// Resolve drag payloads to tracks. Each item is "track::<uuid>",
    /// "album::<id>", or "artist::<id>". Album/artist drops expand to all their
    /// tracks (in index order).
    func tracksForDragItems(_ items: [String]) -> [LoadedTrack] {
        var tracks: [LoadedTrack] = []
        for item in items {
            if item.hasPrefix("track::") {
                let uuidString = String(item.dropFirst("track::".count))
                if let uuid = UUID(uuidString: uuidString),
                   let track = index.allTracks.first(where: { $0.track.id == uuid }) {
                    tracks.append(track)
                }
            } else if item.hasPrefix("album::") {
                let albumID = String(item.dropFirst("album::".count))
                if let album = index.artists.flatMap({ $0.albums }).first(where: { $0.id == albumID }) {
                    tracks.append(contentsOf: album.tracks)
                }
            } else if item.hasPrefix("artist::") {
                let artistID = String(item.dropFirst("artist::".count))
                if let artist = index.artists.first(where: { $0.id == artistID }) {
                    tracks.append(contentsOf: artist.albums.flatMap { $0.tracks })
                }
            }
        }
        return tracks
    }

    func addItemsToCrate(_ items: [String], crateName: String) {
        let tracksToAdd = tracksForDragItems(items)
        guard !tracksToAdd.isEmpty else { return }
        // Copy-on-import only fires when files enter the library — i.e. committing
        // staged tracks OUT of the Prep Crate. Adding between existing crates (or
        // from All Records) is a reference-only move: the files are already indexed,
        // so a WAV you converted or an SFX you're auditioning isn't duplicated.
        let fromPrepCrate = { if case .prepCrate = currentSource { return true } else { return false } }()
        importTracksIntoCrate(tracksToAdd, crateName: crateName, treatAsImport: fromPrepCrate)
    }

    /// Append dragged tracks/albums/artists to an M3U playlist, skipping paths
    /// already in it.
    func addItemsToPlaylist(_ items: [String], playlistName: String) {
        guard var playlist = playlists.first(where: { $0.name == playlistName }) else { return }
        let urls = tracksForDragItems(items).map { $0.track.fileURL }
        guard !urls.isEmpty else { return }

        let existing = Set(playlist.trackURLs.map { $0.standardizedFileURL.path })
        let newURLs = urls.filter { !existing.contains($0.standardizedFileURL.path) }
        guard !newURLs.isEmpty else { return }

        playlist.trackURLs.append(contentsOf: newURLs)
        try? playlistService.savePlaylist(playlist)
        playlists = playlistService.listPlaylists()
        if case .playlist(let currentName) = currentSource, currentName == playlistName {
            selectPlaylist(name: playlistName)
        }
    }

    // MARK: - Album removal

    /// Remove an album's tracks from a single crate (matched by file path).
    /// Files on disk are untouched.
    func removeAlbumFromCrate(_ album: Album, crateName: String) {
        let paths = Set(album.tracks.map { $0.track.fileURL.standardizedFileURL.path })
        var tracks = loadCrateTracks(name: crateName)
        let before = tracks.count
        tracks.removeAll { paths.contains($0.track.fileURL.standardizedFileURL.path) }
        guard tracks.count != before else { return }
        saveCrateTracks(tracks, name: crateName)
        refreshCrateCounts()
        selectSource(currentSource)
        appAlert = .info(title: "Removed from Crate", message: "“\(album.title)” removed from \(crateName).")
    }

    /// Remove all of an artist's tracks from a single crate (matched by file path).
    /// Files on disk are untouched.
    func removeArtistFromCrate(_ artist: Artist, crateName: String) {
        let paths = Set(artist.albums.flatMap { $0.tracks }.map { $0.track.fileURL.standardizedFileURL.path })
        var tracks = loadCrateTracks(name: crateName)
        let before = tracks.count
        tracks.removeAll { paths.contains($0.track.fileURL.standardizedFileURL.path) }
        guard tracks.count != before else { return }
        saveCrateTracks(tracks, name: crateName)
        refreshCrateCounts()
        selectSource(currentSource)
        appAlert = .info(title: "Removed from Crate", message: "“\(artist.name)” removed from \(crateName).")
    }

    // MARK: - Single-track removal (track context menu)

    /// Move tracks from the crate currently being viewed into `target`: add the
    /// references to `target`, then drop them from the source crate. Membership-only
    /// — never copies files on disk, even when copy-on-import is enabled, because the
    /// files already exist wherever they live; only the crate pointers change.
    func moveTracksToCrate(_ tracks: [LoadedTrack], toCrate target: String) {
        guard case .localCrate(let source) = currentSource, source != target else { return }
        guard !tracks.isEmpty else { return }
        let paths = Set(tracks.map { $0.track.fileURL.standardizedFileURL.path })

        // Add references to the target crate (dedup keeps it idempotent).
        // Only remove from the source once the target save actually succeeded —
        // otherwise a full/unmounted volume silently drops the tracks from both.
        var dest = loadCrateTracks(name: target)
        dest.append(contentsOf: tracks)
        guard saveCrateTracks(LibraryViewModel.deduplicate(tracks: dest), name: target) else { return }

        // Remove the same references from the source crate.
        var src = loadCrateTracks(name: source)
        src.removeAll { paths.contains($0.track.fileURL.standardizedFileURL.path) }
        saveCrateTracks(src, name: source)

        refreshCrateCounts()
        selectSource(currentSource)
        appAlert = .info(title: "Moved to Crate",
                         message: "Moved \(tracks.count) \(tracks.count == 1 ? "track" : "tracks") from “\(source)” to “\(target).”")
    }

    func removeTrackFromCrate(_ track: LoadedTrack, crateName: String) {
        let path = track.track.fileURL.standardizedFileURL.path
        var tracks = loadCrateTracks(name: crateName)
        let before = tracks.count
        tracks.removeAll { $0.track.fileURL.standardizedFileURL.path == path }
        guard tracks.count != before else { return }
        saveCrateTracks(tracks, name: crateName)
        refreshCrateCounts()
        selectSource(currentSource)
        appAlert = .info(title: "Removed from Crate", message: "“\(track.track.title)” removed from \(crateName).")
    }

    /// Ask how to remove a single track from the whole library: unload (keep the
    /// file) or move it to the Trash.
    func promptRemoveTrackFromLibrary(_ track: LoadedTrack) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(track.track.title)”?"
        alert.informativeText = """
        Unload removes it from the library and all crates but leaves the file on disk.
        Move to Trash deletes the underlying audio file.
        """
        alert.addButton(withTitle: "Unload")          // .alertFirstButtonReturn
        alert.addButton(withTitle: "Move to Trash")   // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  unloadTrackFromLibrary(track)
        case .alertSecondButtonReturn: trashTrackFile(track)
        default: break
        }
    }

    /// Drop a track from the in-memory library and every crate; keep the file.
    func unloadTrackFromLibrary(_ track: LoadedTrack) {
        purgeTracksFromLibraryState(paths: [track.track.fileURL.standardizedFileURL.path])
        appAlert = .info(
            title: "Removed",
            message: "“\(track.track.title)” removed from the library. The file was left on disk."
        )
    }

    /// Move a track's file to the Trash, then drop it from library + crates.
    func trashTrackFile(_ track: LoadedTrack) {
        let cleanup = LibraryCleanupService()
        do {
            try cleanup.deleteTracks([track], useTrash: true)
            purgeTracksFromLibraryState(paths: [track.track.fileURL.standardizedFileURL.path])
            appAlert = .info(title: "Moved to Trash", message: "“\(track.track.title)” moved to the Trash.")
        } catch {
            appAlert = .error(title: "Trash Failed", message: error.localizedDescription)
        }
    }

    /// Ask how to remove an album from the whole library: unload (keep files),
    /// move the files elsewhere, or move them to the Trash.
    func promptRemoveAlbumFromLibrary(_ album: Album) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(album.title)”?"
        alert.informativeText = """
        Unload removes it from the library and all crates but leaves the files on disk.
        Move… relocates the files to a folder you choose.
        Move to Trash deletes the underlying audio files.
        """
        alert.addButton(withTitle: "Unload")          // .alertFirstButtonReturn
        alert.addButton(withTitle: "Move…")           // .alertSecondButtonReturn
        alert.addButton(withTitle: "Move to Trash")   // .alertThirdButtonReturn
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  unloadAlbumFromLibrary(album)
        case .alertSecondButtonReturn: moveAlbumFiles(album)
        case .alertThirdButtonReturn:  trashAlbumFiles(album)
        default: break
        }
    }

    /// Drop an album from the in-memory library and every crate; keep the files.
    func unloadAlbumFromLibrary(_ album: Album) {
        let paths = Set(album.tracks.map { $0.track.fileURL.standardizedFileURL.path })
        purgeTracksFromLibraryState(paths: paths)
        appAlert = .info(
            title: "Removed",
            message: "“\(album.title)” removed from the library. Files were left on disk."
        )
    }

    /// Move an album's files to the Trash, then drop it from library + crates.
    func trashAlbumFiles(_ album: Album) {
        let cleanup = LibraryCleanupService()
        do {
            try cleanup.deleteTracks(album.tracks, useTrash: true)
            let paths = Set(album.tracks.map { $0.track.fileURL.standardizedFileURL.path })
            purgeTracksFromLibraryState(paths: paths)
            let n = album.tracks.count
            appAlert = .info(
                title: "Moved to Trash",
                message: "“\(album.title)” (\(n) track\(n == 1 ? "" : "s")) moved to the Trash."
            )
        } catch {
            appAlert = .error(title: "Trash Failed", message: error.localizedDescription)
        }
    }

    /// Prompt for a destination folder and move the album's files there,
    /// rewriting the stored paths in the library and every crate.
    func moveAlbumFiles(_ album: Album) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Move “\(album.title)” to…"
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let tracks = album.tracks
        let title = album.title
        scanProgress = ScanProgress(folderName: "Moving “\(title)”…", filesProbed: 0, totalCandidates: tracks.count, isRunning: true)

        Task { [weak self] in
            guard let self else { return }
            do {
                let organizer = LibraryOrganizerService()
                let moved = try await organizer.organize(
                    tracks: tracks,
                    destinationFolder: dest,
                    copyOnly: false,
                    organiseByAlbumArtist: self.prefs.organiseByAlbumArtist
                ) { count, total in
                    Task { @MainActor in
                        self.scanProgress = ScanProgress(folderName: "Moving “\(title)”…", filesProbed: count, totalCandidates: total, isRunning: true)
                    }
                }
                await MainActor.run {
                    self.scanProgress = .idle
                    // organize() returns the updated tracks in input order, so
                    // map each old path to its relocated track.
                    var byOldPath: [String: LoadedTrack] = [:]
                    for (old, new) in zip(tracks, moved) {
                        byOldPath[old.track.fileURL.standardizedFileURL.path] = new
                    }
                    self.rewriteTrackPaths(byOldPath)
                    self.appAlert = .info(title: "Album Moved", message: "“\(title)” moved to \(dest.path).")
                }
            } catch {
                await MainActor.run {
                    self.scanProgress = .idle
                    self.appAlert = .error(title: "Move Failed", message: error.localizedDescription)
                }
            }
        }
    }

    /// Remove tracks (matched by file path) from the local index, prep crate,
    /// and every saved crate. Does NOT touch files on disk.
    func purgeTracksFromLibraryState(paths: Set<String>) {
        let remaining = localIndex.allTracks.filter {
            !paths.contains($0.track.fileURL.standardizedFileURL.path)
        }
        localIndex = buildIndex(remaining)
        prepCrateTracks.removeAll { paths.contains($0.track.fileURL.standardizedFileURL.path) }
        // Purged tracks leave the shared store too, or it grows dead entries
        // forever. One store write for the whole purge, not one per crate.
        let store = currentTrackStore()
        for path in paths { store.remove(path: path) }
        for crateName in availableCrates {
            var tracks = loadCrateTracks(name: crateName)
            let before = tracks.count
            tracks.removeAll { paths.contains($0.track.fileURL.standardizedFileURL.path) }
            if tracks.count != before { saveCrateTracks(tracks, name: crateName, persistStore: false) }
        }
        persistTrackStore()
        refreshCrateCounts()
        selectSource(currentSource)
    }

    /// Rewrite stored file paths (old path → relocated track) across the local
    /// index, prep crate, and every crate after files are moved on disk.
    private func rewriteTrackPaths(_ byOldPath: [String: LoadedTrack]) {
        let newLocal = localIndex.allTracks.map {
            byOldPath[$0.track.fileURL.standardizedFileURL.path] ?? $0
        }
        localIndex = buildIndex(newLocal)
        prepCrateTracks = prepCrateTracks.map {
            byOldPath[$0.track.fileURL.standardizedFileURL.path] ?? $0
        }
        // Repoint the shared store first (dropping the now-dead old keys), then
        // rewrite memberships. One store write total — per-crate saves re-encode
        // the whole store and froze the UI for seconds on a library move.
        let store = currentTrackStore()
        let newKeys = Set(byOldPath.values.map { TrackStore.key(for: $0.track.fileURL) })
        for (oldPath, new) in byOldPath {
            store.upsert(new)
            if !newKeys.contains(oldPath) { store.remove(path: oldPath) }
        }
        for crateName in availableCrates {
            var tracks = loadCrateTracks(name: crateName)
            var modified = false
            for i in tracks.indices {
                if let new = byOldPath[tracks[i].track.fileURL.standardizedFileURL.path] {
                    tracks[i] = new
                    modified = true
                }
            }
            if modified { saveCrateTracks(tracks, name: crateName, persistStore: false) }
        }
        persistTrackStore()
        refreshCrateCounts()
        selectSource(currentSource)
    }

    func addURLsToCrate(_ urls: [URL], crateName: String) {
        // Scan files dropped from Finder
        scanProgress = ScanProgress(folderName: "Scanning dropped files...", filesProbed: 0, totalCandidates: nil, isRunning: true)
        
        Task { [weak self] in
            guard let self else { return }
            var collected: [LoadedTrack] = []
            for url in urls {
                let scanned = await self.scanner.scanFolder(url)
                collected.append(contentsOf: scanned)
            }
            
            let deduplicated = LibraryViewModel.deduplicate(tracks: collected)
            
            await MainActor.run {
                self.scanProgress = .idle
                // Files dropped from Finder are genuinely new to the app, so this is
                // a real import — honor copy-on-import.
                self.importTracksIntoCrate(deduplicated, crateName: crateName, treatAsImport: true)
            }
        }
    }

    /// - Parameter treatAsImport: whether these tracks are *entering* the library
    ///   (Prep-Crate commit or a fresh Finder drop). Only then does copy-on-import
    ///   apply; reference-only crate moves pass `false` so nothing is duplicated.
    private func importTracksIntoCrate(_ tracks: [LoadedTrack], crateName: String, treatAsImport: Bool) {
        beginImportStatus(count: tracks.count, crateName: crateName)
        let copyEnabled = prefs.copyOnImport && treatAsImport
        let libraryFolderURL = managedLibraryFolderURL
        
        if copyEnabled, let destURL = libraryFolderURL {
            // Copy files to the library folder in background
            scanProgress = ScanProgress(folderName: "Copying to library...", filesProbed: 0, totalCandidates: tracks.count, isRunning: true)
            
            Task { [weak self] in
                guard let self else { return }
                let organizer = LibraryOrganizerService()
                do {
                    let updatedTracks = try await organizer.organize(
                        tracks: tracks,
                        destinationFolder: destURL,
                        copyOnly: !self.prefs.deleteOriginalsAfterCopy,
                        organiseByAlbumArtist: self.prefs.organiseByAlbumArtist
                    ) { [weak self] count, total in
                        Task { @MainActor in
                            self?.scanProgress = ScanProgress(
                                folderName: "Copying to library...",
                                filesProbed: count,
                                totalCandidates: total,
                                isRunning: true
                            )
                        }
                    }
                    
                    await MainActor.run {
                        self.appendTracksToCrateFile(updatedTracks, crateName: crateName)
                        self.finishImportStatus(count: tracks.count, crateName: crateName)
                    }
                } catch {
                    await MainActor.run {
                        self.scanProgress = .idle
                        self.appAlert = .error(title: "Copy Failed", message: "Failed to copy files: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Index files in place
            appendTracksToCrateFile(tracks, crateName: crateName)
            finishImportStatus(count: tracks.count, crateName: crateName)
        }
    }

    /// Switch the OLED to SCAN and show an "adding" status while tracks are added
    /// to a crate. Remembers the prior view so `finishImportStatus` can restore it.
    private func beginImportStatus(count: Int, crateName: String) {
        if oledView != .scan { importStatusReturnOLED = oledView }
        oledView = .scan
        scanProgress = ScanProgress(folderName: "Adding → \(crateName)", filesProbed: 0,
                                    totalCandidates: count, isRunning: true)
    }

    /// Show a brief "added" confirmation on the SCAN OLED, then restore the prior
    /// view after a short delay.
    private func finishImportStatus(count: Int, crateName: String) {
        scanProgress = ScanProgress(folderName: "Added \(count) → \(crateName)", filesProbed: count,
                                    totalCandidates: count, isRunning: false)
        let revertTo = importStatusReturnOLED ?? .nowPlaying
        importStatusReturnOLED = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            if self.oledView == .scan { self.oledView = revertTo }
            if !self.scanProgress.isRunning { self.scanProgress = .idle }
        }
    }

    private func appendTracksToCrateFile(_ newTracks: [LoadedTrack], crateName: String) {
        var existing = loadCrateTracks(name: crateName)
        existing.append(contentsOf: newTracks)
        let merged = LibraryViewModel.deduplicate(tracks: existing)
        saveCrateTracks(merged, name: crateName)

        // Land in the destination crate and reveal the album we just added, so an
        // add is visible instead of silently mutating a crate off-screen.
        // selectSource rebuilds `index` from the crate and resets selection to the
        // first album — so we set our reveal target *after* it.
        selectSource(.localCrate(name: crateName))
        revealAlbum(containingTrackID: newTracks.last?.track.id)
    }

    /// Select and scroll-reveal the album containing `trackID` in the current
    /// `index`. Setting `selectedAlbumID` drives the browser's ScrollViewReader to
    /// center the row; `selectedArtistID` keeps the Album column on the right
    /// artist in the full three-column layout. No-op if the track isn't found.
    private func revealAlbum(containingTrackID trackID: UUID?) {
        guard let trackID else { return }
        for artist in index.artists {
            for album in artist.albums {
                if album.tracks.contains(where: { $0.track.id == trackID }) {
                    selectedArtistID = album.artistID
                    selectedAlbumID = album.id
                    selectedTrackID = trackID
                    return
                }
                for version in album.versions ?? [] where version.tracks.contains(where: { $0.track.id == trackID }) {
                    selectedArtistID = version.artistID
                    selectedAlbumID = version.id
                    selectedTrackID = trackID
                    return
                }
            }
        }
    }

    func updateTrackURLInIndex(oldURL: URL, newTrack: LoadedTrack) {
        // When a track's file path changes (tag edit + auto-organise), drop the
        // stale store key and let the shared funnel update the Prep Crate and
        // every crate that references it — patching only saved crates left
        // staged tracks pointing at the pre-move path.
        let oldKey = TrackStore.key(for: oldURL)
        if oldKey != TrackStore.key(for: newTrack.track.fileURL) {
            currentTrackStore().remove(path: oldKey)
        }
        replaceTrackEverywhere(matchingPath: oldURL.path, with: newTrack)
    }

    /// Batch variant of `updateTrackURLInIndex`: repoint many tracks in one pass,
    /// loading + saving each crate at most once. Matches by stable track id (the
    /// relocated tracks keep their id via `withFileURL`), so a whole moved folder
    /// re-attaches without rewriting every crate per file.
    func updateTrackURLsInIndex(_ newTracks: [LoadedTrack]) {
        guard !newTracks.isEmpty else { return }
        let byID = Dictionary(newTracks.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The staging area holds tracks too — leaving it stale points staged
        // entries at pre-move paths (unplayable until rescan).
        for i in prepCrateTracks.indices {
            if let replacement = byID[prepCrateTracks[i].track.id] {
                prepCrateTracks[i] = replacement
            }
        }
        let store = currentTrackStore()
        var staleKeys = Set<String>()
        for crateName in availableCrates {
            var tracks = loadCrateTracks(name: crateName)
            var modified = false
            for i in 0..<tracks.count {
                if let replacement = byID[tracks[i].track.id] {
                    let oldKey = TrackStore.key(for: tracks[i].track.fileURL)
                    if oldKey != TrackStore.key(for: replacement.track.fileURL) {
                        staleKeys.insert(oldKey)
                    }
                    tracks[i] = replacement
                    modified = true
                }
            }
            if modified {
                saveCrateTracks(tracks, name: crateName, persistStore: false)
            }
        }
        // Drop dead old-path keys, then persist the store once for the batch.
        let liveKeys = Set(newTracks.map { TrackStore.key(for: $0.track.fileURL) })
        for key in staleKeys.subtracting(liveKeys) { store.remove(path: key) }
        persistTrackStore()
        selectSource(currentSource)
    }

    func moveLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose new location for Music Library"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let newURL = panel.url else { return }

        guard let currentURL = managedLibraryFolderURL else {
            do {
                let data = try PreferencesStore.makeBookmark(for: newURL)
                prefs.managedLibraryFolderBookmark = data
                NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerLibraryFolderChanged"), object: newURL)
                appAlert = .error(title: "Library Set", message: "Library folder set to: \(newURL.path)")
            } catch {
                appAlert = .error(title: "Failed", message: "Could not set library: \(error.localizedDescription)")
            }
            return
        }

        if currentURL.standardizedFileURL.path == newURL.standardizedFileURL.path {
            appAlert = .error(title: "Same Folder", message: "The chosen folder is the same as the current library folder.")
            return
        }

        scanProgress = ScanProgress(folderName: "Moving library files...", filesProbed: 0, totalCandidates: nil, isRunning: true)

        Task { [weak self] in
            guard let self else { return }
            // Find all tracks across all crates that are inside the current library folder
            var allTracksInLib: [LoadedTrack] = []
            for name in self.availableCrates {
                allTracksInLib.append(contentsOf: self.loadCrateTracks(name: name))
            }
            let uniqueTracksInLib = LibraryViewModel.deduplicate(tracks: allTracksInLib).filter {
                $0.track.fileURL.path.hasPrefix(currentURL.path)
            }

            let organizer = LibraryOrganizerService()
            // Failure-reporting variant: a file that fails mid-batch no
            // longer aborts the move and discards the repointed tracks —
            // everything that DID move still gets its crates rewritten.
            let result = await organizer.organizeReportingFailures(
                tracks: uniqueTracksInLib,
                destinationFolder: newURL,
                copyOnly: false, // Move!
                organiseByAlbumArtist: self.prefs.organiseByAlbumArtist
            ) { [weak self] count, total in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(
                        folderName: "Moving library files...",
                        filesProbed: count,
                        totalCandidates: total,
                        isRunning: true
                    )
                }
            }
            let updatedTracks = result.tracks

            await MainActor.run {
                // Repoint crates at the moved files FIRST — the files are
                // already at the new location, so a bookmark failure below
                // must not leave every crate referencing dead paths. The
                // batch helper loads/saves each crate once (the old
                // per-track × per-crate loop re-encoded the whole store
                // thousands of times on a large move).
                self.updateTrackURLsInIndex(updatedTracks)
                self.scanProgress = .idle
                do {
                    let data = try PreferencesStore.makeBookmark(for: newURL)
                    self.prefs.managedLibraryFolderBookmark = data
                    NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerLibraryFolderChanged"), object: newURL)
                    if result.failures.isEmpty {
                        self.appAlert = .error(title: "Library Moved", message: "Successfully moved library files to the new location.")
                    } else {
                        self.appAlert = .error(title: "Library Moved (with issues)",
                                               message: "Moved with \(result.failures.count) failure(s) — those files stayed at the old location:\n"
                                                   + result.failures.prefix(5).joined(separator: "\n"))
                    }
                } catch {
                    self.appAlert = .error(title: "Save Failed",
                                           message: "Files moved and crates updated, but the new folder couldn't be saved as the library location: \(error.localizedDescription)")
                }
            }
        }
    }

    func consolidateLibrary() {
        guard let libraryFolderURL = managedLibraryFolderURL else {
            appAlert = .error(title: "No Library Folder", message: "Please set a library folder in Preferences first.")
            return
        }

        // Find all tracks across all crates that are NOT in the library folder
        var allTracks: [LoadedTrack] = []
        for name in availableCrates {
            allTracks.append(contentsOf: loadCrateTracks(name: name))
        }
        let tracksOutside = LibraryViewModel.deduplicate(tracks: allTracks).filter {
            !$0.track.fileURL.path.hasPrefix(libraryFolderURL.path)
        }

        guard !tracksOutside.isEmpty else {
            appAlert = .error(title: "Consolidated", message: "All tracks are already inside your library folder.")
            return
        }

        scanProgress = ScanProgress(folderName: "Consolidating library...", filesProbed: 0, totalCandidates: tracksOutside.count, isRunning: true)

        Task { [weak self] in
            guard let self else { return }
            let organizer = LibraryOrganizerService()
            // Failure-reporting variant: tracks that DID copy still get their
            // crates repointed even if a later file fails.
            let result = await organizer.organizeReportingFailures(
                tracks: tracksOutside,
                destinationFolder: libraryFolderURL,
                copyOnly: true, // Copy, keeping originals
                organiseByAlbumArtist: self.prefs.organiseByAlbumArtist
            ) { [weak self] count, total in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(
                        folderName: "Consolidating library...",
                        filesProbed: count,
                        totalCandidates: total,
                        isRunning: true
                    )
                }
            }

            await MainActor.run {
                // Batch crate rewrite: loads/saves each crate once (the old
                // per-track × per-crate loop re-encoded the whole store per hit).
                self.updateTrackURLsInIndex(result.tracks)
                self.scanProgress = .idle
                if result.failures.isEmpty {
                    self.appAlert = .error(title: "Consolidation Complete", message: "Successfully consolidated \(tracksOutside.count) external tracks into your library folder.")
                } else {
                    self.appAlert = .error(title: "Consolidated (with issues)",
                                           message: "\(result.failures.count) file(s) could not be copied:\n"
                                               + result.failures.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }
}
