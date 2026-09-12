import Foundation

/// What CrateDigger is playing, as the Now Playing widget sees it.
///
/// The app writes one of these into the app-group container whenever the
/// system's now-playing info changes; the widget reads it back and draws.
/// Nothing ever travels the other way.
public struct NowPlayingFeed: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case idle, playing, paused }

    public var state: State
    public var title: String
    public var artist: String
    public var album: String
    /// A radio stream: no duration, no progress bar.
    public var isLive: Bool
    public var duration: Double
    /// Seconds into the track as of `playheadAt`. The widget extrapolates
    /// from the pair while `state == .playing`, so the app never has to
    /// write on a tick.
    public var playhead: Double
    public var playheadAt: Date
    /// File name inside the container (`art-<hash>.jpg`), nil for no art.
    public var artworkFile: String?

    public init(state: State = .idle, title: String = "", artist: String = "", album: String = "",
                isLive: Bool = false, duration: Double = 0, playhead: Double = 0,
                playheadAt: Date = .distantPast, artworkFile: String? = nil) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.isLive = isLive
        self.duration = duration
        self.playhead = playhead
        self.playheadAt = playheadAt
        self.artworkFile = artworkFile
    }

    public static let idle = NowPlayingFeed()

    /// The app group both the app and the widget are entitled to. macOS
    /// group identifiers are team-prefixed (`TEAMID.name`), unlike iOS's
    /// `group.` form.
    public static let groupIdentifier = "L26TPPMPF3.com.cratedigger.shared"

    /// The widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    public static let widgetKind = "NowPlaying"

    /// The shared container, or nil when the process is not entitled to it.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }
}

/// The feed on disk: one JSON file plus at most one artwork file beside it.
public struct NowPlayingFeedStore: Sendable {
    public static let feedFileName = "now-playing.json"
    private static let artworkPrefix = "art-"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Write `feed` unless the file already holds exactly these bytes, and
    /// say whether anything changed, so the caller reloads the widget only
    /// then. `artwork` is asked for bytes only when the feed names an art file
    /// that is not on disk yet; with none to give, the feed goes out without
    /// art. Art files the feed no longer names are removed.
    @discardableResult
    public func write(_ feed: NowPlayingFeed, artwork: () -> Data?) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var feed = feed
        if let name = feed.artworkFile {
            let url = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                if let data = artwork() {
                    try data.write(to: url, options: .atomic)
                } else {
                    feed.artworkFile = nil
                }
            }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.artworkPrefix) && name != feed.artworkFile {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(feed)
        let url = directory.appendingPathComponent(Self.feedFileName)
        if (try? Data(contentsOf: url)) == data { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    /// The last feed written, or idle when there is none or it cannot be read.
    public func read() -> NowPlayingFeed {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.feedFileName)),
              let feed = try? JSONDecoder().decode(NowPlayingFeed.self, from: data)
        else { return .idle }
        return feed
    }

    /// The feed's artwork file, when it names one that is on disk.
    public func artworkURL(for feed: NowPlayingFeed) -> URL? {
        guard let name = feed.artworkFile else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The artwork file name for an artwork hash.
    public static func artworkFileName(forHash hash: String) -> String {
        "\(artworkPrefix)\(hash).jpg"
    }
}
