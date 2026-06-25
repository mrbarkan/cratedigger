import Foundation

public final class PreferencesStore {

    public static let shared = PreferencesStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let windowFrame = "cratedigger.window.frame"
        static let libraryFolderBookmarks = "cratedigger.library.folderBookmarks"
        static let outputDestinationBookmark = "cratedigger.conversion.outputBookmark"
        static let externalDeviceProfiles = "cratedigger.externalDevices.profiles"
        static let lastConversionSelection = "cratedigger.conversion.lastSelection"
        static let customFFmpegPath = "cratedigger.tools.ffmpegPath"
        static let customFFprobePath = "cratedigger.tools.ffprobePath"
        static let oledView = "cratedigger.ui.oledView"
        static let shuffleEnabled = "cratedigger.playback.shuffle"
        static let repeatMode = "cratedigger.playback.repeatMode"
        static let clickSoundsEnabled = "cratedigger.ui.clickSoundsEnabled"
        static let subsonicURL = "cratedigger.remote.subsonicURL"
        static let subsonicUsername = "cratedigger.remote.subsonicUsername"
        static let subsonicPassword = "cratedigger.remote.subsonicPassword"
        static let lastFmUsername = "cratedigger.lastfm.username"
        static let lastFmSessionKey = "cratedigger.lastfm.sessionKey"
        static let outputDeviceUID = "cratedigger.audio.outputDeviceUID"
        static let keyboardShortcuts = "cratedigger.ui.keyboardShortcuts"
        static let cdAnimationSpeed = "cratedigger.ui.cdAnimationSpeed"
        static let managedLibraryFolderBookmark = "cratedigger.library.managedFolderBookmark"
        static let copyOnImport = "cratedigger.library.copyOnImport"
        static let deleteOriginalsAfterCopy = "cratedigger.library.deleteOriginalsAfterCopy"
        static let organiseByAlbumArtist = "cratedigger.library.organiseByAlbumArtist"
        static let keepLibraryOrganised = "cratedigger.library.keepLibraryOrganised"
        static let cratesIndexFolderBookmark = "cratedigger.library.cratesIndexFolderBookmark"
        static let trackSortField = "cratedigger.browser.trackSortField"
        static let trackSortAscending = "cratedigger.browser.trackSortAscending"
        static let artistSortField = "cratedigger.browser.artistSortField"
        static let artistSortAscending = "cratedigger.browser.artistSortAscending"
        static let albumSortField = "cratedigger.browser.albumSortField"
        static let albumSortAscending = "cratedigger.browser.albumSortAscending"
        static let showSortControls = "cratedigger.browser.showSortControls"
        static let browserLayout = "cratedigger.browser.layout"
        static let scrubLock = "cratedigger.transport.scrubLock"
        static let miniPlayerArtMode = "cratedigger.miniplayer.artMode"
        static let hasCompletedFirstRunSetup = "cratedigger.onboarding.completed"
        static let streamSources = "cratedigger.radio.streamSources"
        static let streamEngine = "cratedigger.radio.engine"
        static let customYtDlpPath = "cratedigger.tools.ytdlpPath"
    }

    // MARK: - Window frame

    public var savedWindowFrame: CGRect? {
        get {
            guard let data = defaults.data(forKey: Key.windowFrame) else { return nil }
            return try? decoder.decode(CGRect.self, from: data)
        }
        set {
            if let value = newValue, let data = try? encoder.encode(value) {
                defaults.set(data, forKey: Key.windowFrame)
            } else {
                defaults.removeObject(forKey: Key.windowFrame)
            }
        }
    }

    // MARK: - Library folder bookmarks

    public var savedLibraryFolderBookmarks: [Data] {
        get { defaults.array(forKey: Key.libraryFolderBookmarks) as? [Data] ?? [] }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.libraryFolderBookmarks)
            } else {
                defaults.set(newValue, forKey: Key.libraryFolderBookmarks)
            }
        }
    }

    // MARK: - Managed Library Folder Settings

    public var managedLibraryFolderBookmark: Data? {
        get { defaults.data(forKey: Key.managedLibraryFolderBookmark) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.managedLibraryFolderBookmark)
            } else {
                defaults.removeObject(forKey: Key.managedLibraryFolderBookmark)
            }
        }
    }

    public var copyOnImport: Bool {
        get {
            if defaults.object(forKey: Key.copyOnImport) == nil { return true }
            return defaults.bool(forKey: Key.copyOnImport)
        }
        set { defaults.set(newValue, forKey: Key.copyOnImport) }
    }

    public var deleteOriginalsAfterCopy: Bool {
        get { defaults.bool(forKey: Key.deleteOriginalsAfterCopy) }
        set { defaults.set(newValue, forKey: Key.deleteOriginalsAfterCopy) }
    }

    public var organiseByAlbumArtist: Bool {
        get {
            if defaults.object(forKey: Key.organiseByAlbumArtist) == nil { return true }
            return defaults.bool(forKey: Key.organiseByAlbumArtist)
        }
        set { defaults.set(newValue, forKey: Key.organiseByAlbumArtist) }
    }

    public var keepLibraryOrganised: Bool {
        get {
            if defaults.object(forKey: Key.keepLibraryOrganised) == nil { return true }
            return defaults.bool(forKey: Key.keepLibraryOrganised)
        }
        set { defaults.set(newValue, forKey: Key.keepLibraryOrganised) }
    }

    public var cratesIndexFolderBookmark: Data? {
        get { defaults.data(forKey: Key.cratesIndexFolderBookmark) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.cratesIndexFolderBookmark)
            } else {
                defaults.removeObject(forKey: Key.cratesIndexFolderBookmark)
            }
        }
    }

    // MARK: - Output destination bookmark

    public var savedOutputDestinationBookmark: Data? {
        get { defaults.data(forKey: Key.outputDestinationBookmark) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.outputDestinationBookmark)
            } else {
                defaults.removeObject(forKey: Key.outputDestinationBookmark)
            }
        }
    }

    // MARK: - External device profiles

    public var savedExternalDeviceProfiles: [ExternalDeviceProfile] {
        get {
            guard let data = defaults.data(forKey: Key.externalDeviceProfiles) else {
                return []
            }
            return (try? decoder.decode([ExternalDeviceProfile].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.externalDeviceProfiles)
            } else if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.externalDeviceProfiles)
            }
        }
    }

    public func upsertExternalDeviceProfile(_ profile: ExternalDeviceProfile) {
        var profiles = savedExternalDeviceProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        savedExternalDeviceProfiles = profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func removeExternalDeviceProfile(id: UUID) {
        savedExternalDeviceProfiles = savedExternalDeviceProfiles.filter { $0.id != id }
    }

    // MARK: - Last-used conversion selection

    public func savedLastConversionSelection<T: Decodable>(as type: T.Type) -> T? {
        guard let data = defaults.data(forKey: Key.lastConversionSelection) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public func saveLastConversionSelection<T: Encodable>(_ value: T) {
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: Key.lastConversionSelection)
        }
    }

    public func clearLastConversionSelection() {
        defaults.removeObject(forKey: Key.lastConversionSelection)
    }

    // MARK: - Custom tool paths

    public var customFFmpegPath: String? {
        get { defaults.string(forKey: Key.customFFmpegPath) }
        set {
            if let value = newValue, !value.isEmpty {
                defaults.set(value, forKey: Key.customFFmpegPath)
            } else {
                defaults.removeObject(forKey: Key.customFFmpegPath)
            }
        }
    }

    public var customFFprobePath: String? {
        get { defaults.string(forKey: Key.customFFprobePath) }
        set {
            if let value = newValue, !value.isEmpty {
                defaults.set(value, forKey: Key.customFFprobePath)
            } else {
                defaults.removeObject(forKey: Key.customFFprobePath)
            }
        }
    }

    // MARK: - UI state

    public var savedOLEDView: String? {
        get { defaults.string(forKey: Key.oledView) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Key.oledView)
            } else {
                defaults.removeObject(forKey: Key.oledView)
            }
        }
    }

    public var savedShuffleEnabled: Bool {
        get { defaults.bool(forKey: Key.shuffleEnabled) }
        set { defaults.set(newValue, forKey: Key.shuffleEnabled) }
    }

    public var savedRepeatMode: String? {
        get { defaults.string(forKey: Key.repeatMode) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Key.repeatMode)
            } else {
                defaults.removeObject(forKey: Key.repeatMode)
            }
        }
    }

    public var savedTrackSortField: String? {
        get { defaults.string(forKey: Key.trackSortField) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Key.trackSortField)
            } else {
                defaults.removeObject(forKey: Key.trackSortField)
            }
        }
    }

    public var savedBrowserLayout: String? {
        get { defaults.string(forKey: Key.browserLayout) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Key.browserLayout)
            } else {
                defaults.removeObject(forKey: Key.browserLayout)
            }
        }
    }

    public var savedScrubLockEnabled: Bool {
        get { defaults.bool(forKey: Key.scrubLock) }
        set { defaults.set(newValue, forKey: Key.scrubLock) }
    }

    public var savedMiniPlayerArtMode: String? {
        get { defaults.string(forKey: Key.miniPlayerArtMode) }
        set {
            if let value = newValue { defaults.set(value, forKey: Key.miniPlayerArtMode) }
            else { defaults.removeObject(forKey: Key.miniPlayerArtMode) }
        }
    }

    public var hasCompletedFirstRunSetup: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRunSetup) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRunSetup) }
    }

    public var savedTrackSortAscending: Bool {
        get {
            // Default ascending when never set.
            if defaults.object(forKey: Key.trackSortAscending) == nil { return true }
            return defaults.bool(forKey: Key.trackSortAscending)
        }
        set { defaults.set(newValue, forKey: Key.trackSortAscending) }
    }

    public var savedArtistSortField: String? {
        get { defaults.string(forKey: Key.artistSortField) }
        set {
            if let value = newValue { defaults.set(value, forKey: Key.artistSortField) }
            else { defaults.removeObject(forKey: Key.artistSortField) }
        }
    }

    public var savedArtistSortAscending: Bool {
        get {
            if defaults.object(forKey: Key.artistSortAscending) == nil { return true }
            return defaults.bool(forKey: Key.artistSortAscending)
        }
        set { defaults.set(newValue, forKey: Key.artistSortAscending) }
    }

    public var savedAlbumSortField: String? {
        get { defaults.string(forKey: Key.albumSortField) }
        set {
            if let value = newValue { defaults.set(value, forKey: Key.albumSortField) }
            else { defaults.removeObject(forKey: Key.albumSortField) }
        }
    }

    public var savedAlbumSortAscending: Bool {
        get {
            if defaults.object(forKey: Key.albumSortAscending) == nil { return true }
            return defaults.bool(forKey: Key.albumSortAscending)
        }
        set { defaults.set(newValue, forKey: Key.albumSortAscending) }
    }

    public var savedShowSortControls: Bool {
        get {
            // Default visible when never set.
            if defaults.object(forKey: Key.showSortControls) == nil { return true }
            return defaults.bool(forKey: Key.showSortControls)
        }
        set { defaults.set(newValue, forKey: Key.showSortControls) }
    }

    public var clickSoundsEnabled: Bool {
        get {
            // Default true so the skeuomorphic feel is on out of the box.
            // Use object(forKey:) so we can distinguish "never set" from "set to false".
            if defaults.object(forKey: Key.clickSoundsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.clickSoundsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.clickSoundsEnabled) }
    }

    // MARK: - Subsonic Remote Library

    public var subsonicURL: String? {
        get { defaults.string(forKey: Key.subsonicURL) }
        set { defaults.set(newValue, forKey: Key.subsonicURL) }
    }

    public var subsonicUsername: String? {
        get { defaults.string(forKey: Key.subsonicUsername) }
        set { defaults.set(newValue, forKey: Key.subsonicUsername) }
    }

    public var subsonicPassword: String? {
        get { defaults.string(forKey: Key.subsonicPassword) }
        set { defaults.set(newValue, forKey: Key.subsonicPassword) }
    }

    // MARK: - Last.fm

    public var lastFmUsername: String? {
        get { defaults.string(forKey: Key.lastFmUsername) }
        set { defaults.set(newValue, forKey: Key.lastFmUsername) }
    }

    public var lastFmSessionKey: String? {
        get { defaults.string(forKey: Key.lastFmSessionKey) }
        set { defaults.set(newValue, forKey: Key.lastFmSessionKey) }
    }

    // MARK: - Audio Device Selection

    public var selectedOutputDeviceUID: String? {
        get { defaults.string(forKey: Key.outputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.outputDeviceUID) }
    }

    // MARK: - Custom Keyboard Shortcuts

    public var keyboardShortcuts: [String: String] {
        get { defaults.dictionary(forKey: Key.keyboardShortcuts) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.keyboardShortcuts) }
    }

    // MARK: - Radio / Streams

    /// Raw JSON of `[StreamSource]`. `StreamStore` owns (de)serialization.
    public var streamSourcesData: Data? {
        get { defaults.data(forKey: Key.streamSources) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.streamSources)
            } else {
                defaults.removeObject(forKey: Key.streamSources)
            }
        }
    }

    /// "auto" | "native" | "webview". Defaults to "auto" (native if yt-dlp is present, else webview).
    public var streamEngine: String {
        get { defaults.string(forKey: Key.streamEngine) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.streamEngine) }
    }

    /// User-chosen path to a yt-dlp binary (bring-your-own). nil/empty clears it.
    public var customYtDlpPath: String? {
        get { defaults.string(forKey: Key.customYtDlpPath) }
        set {
            if let value = newValue, !value.isEmpty {
                defaults.set(value, forKey: Key.customYtDlpPath)
            } else {
                defaults.removeObject(forKey: Key.customYtDlpPath)
            }
        }
    }

    // MARK: - Reset

    public func resetAll() {
        let domain = Bundle.main.bundleIdentifier
            ?? defaults.persistentDomain(forName: "")?.keys.first.map { _ in "" }
            ?? ""
        if !domain.isEmpty {
            defaults.removePersistentDomain(forName: domain)
        }
        for key in [
            Key.windowFrame,
            Key.libraryFolderBookmarks,
            Key.outputDestinationBookmark,
            Key.externalDeviceProfiles,
            Key.lastConversionSelection,
            Key.customFFmpegPath,
            Key.customFFprobePath,
            Key.oledView,
            Key.shuffleEnabled,
            Key.repeatMode,
            Key.cdAnimationSpeed,
            Key.managedLibraryFolderBookmark,
            Key.copyOnImport,
            Key.deleteOriginalsAfterCopy,
            Key.organiseByAlbumArtist,
            Key.keepLibraryOrganised
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Bookmark helpers

    public struct ResolvedBookmark {
        public let url: URL
        public let isStale: Bool
    }

    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolveBookmark(_ data: Data) -> ResolvedBookmark? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            AppLog.prefs.warning("Failed to resolve bookmark: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public static func refreshBookmarkIfStale(_ data: Data) -> (Data, ResolvedBookmark)? {
        guard let resolved = resolveBookmark(data) else { return nil }
        guard resolved.isStale else { return (data, resolved) }
        guard let refreshed = try? makeBookmark(for: resolved.url) else { return (data, resolved) }
        return (refreshed, ResolvedBookmark(url: resolved.url, isStale: false))
    }
}

// MARK: - CD Animation Speed Settings

public enum CDAnimationSpeed: String, CaseIterable, Codable, Sendable {
    case fast = "fast"
    case medium = "medium"
    case slow = "slow"
    case none = "none"
    
    public var label: String {
        switch self {
        case .fast: return "Fast/Realistic"
        case .medium: return "Medium"
        case .slow: return "Slow (Vinyl-like)"
        case .none: return "No Motion"
        }
    }
    
    public var angleIncrement: Double {
        switch self {
        case .fast: return 50.0
        case .medium: return 15.0
        case .slow: return 3.3
        case .none: return 0.0
        }
    }
}

public extension PreferencesStore {
    var cdAnimationSpeed: CDAnimationSpeed {
        get {
            guard let raw = defaults.string(forKey: Key.cdAnimationSpeed),
                  let speed = CDAnimationSpeed(rawValue: raw) else {
                return .fast
            }
            return speed
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.cdAnimationSpeed)
        }
    }
}
