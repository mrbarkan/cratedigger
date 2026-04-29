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
        static let lastConversionSelection = "cratedigger.conversion.lastSelection"
        static let customFFmpegPath = "cratedigger.tools.ffmpegPath"
        static let customFFprobePath = "cratedigger.tools.ffprobePath"
        static let oledView = "cratedigger.ui.oledView"
        static let shuffleEnabled = "cratedigger.playback.shuffle"
        static let repeatMode = "cratedigger.playback.repeatMode"
        static let clickSoundsEnabled = "cratedigger.ui.clickSoundsEnabled"
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

    public var clickSoundsEnabled: Bool {
        get {
            // Default true so the skeuomorphic feel is on out of the box.
            // Use object(forKey:) so we can distinguish "never set" from "set to false".
            if defaults.object(forKey: Key.clickSoundsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.clickSoundsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.clickSoundsEnabled) }
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
            Key.lastConversionSelection,
            Key.customFFmpegPath,
            Key.customFFprobePath,
            Key.oledView,
            Key.shuffleEnabled,
            Key.repeatMode
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
