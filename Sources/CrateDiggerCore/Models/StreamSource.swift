import Foundation

/// The kind of YouTube resource a stream points at. Drives playback behaviour
/// (live = no seek, "ON AIR") and the badge shown in the radio list / inspector.
public enum StreamKind: String, Codable, Sendable, CaseIterable {
    case live
    case video
    case mix
    case playlist
}

/// Where a stream comes from. Only YouTube is supported today; the enum exists
/// so the model and UI don't hard-code "YouTube" everywhere.
public enum StreamProvider: String, Codable, Sendable {
    case youtube
}

/// A grouping of streams shown as a "source" row in the sidebar — a provider +
/// liveness pairing ("YT Live", "YT Records"). The sidebar lists the populated
/// categories rather than one row per channel, so new providers slot in here.
public enum RadioCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case youtubeLive
    case youtubeRecords
    /// A filter over the other two categories, not a third home: `of(_:)`
    /// never returns it, so a downloaded YT Records stream still shows in its
    /// own row too, not just here.
    case downloaded

    /// Display name shown in the sidebar.
    public var title: String {
        switch self {
        case .youtubeLive:    return "YT Live"
        case .youtubeRecords: return "YT Records"
        case .downloaded:     return "Downloads"
        }
    }

    /// SF Symbol for the sidebar row.
    public var iconName: String {
        switch self {
        case .youtubeLive:    return "antenna.radiowaves.left.and.right"
        case .youtubeRecords: return "waveform"
        case .downloaded:     return "arrow.down.circle"
        }
    }

    /// The category a stream falls into.
    public static func of(_ stream: StreamSource) -> RadioCategory {
        switch stream.provider {
        case .youtube: return stream.isLive ? .youtubeLive : .youtubeRecords
        }
    }

    /// Whether a stream belongs to this category. `downloaded` is a filter over
    /// the other two, not a home: `of(_:)` never returns it.
    public func contains(_ stream: StreamSource) -> Bool {
        // ponytail: one stat per stream per sidebar draw; cache if lists reach hundreds.
        self == .downloaded ? stream.isDownloaded() : RadioCategory.of(stream) == self
    }
}

/// A timestamped section of a video (a YouTube "chapter"). For long mixes these
/// are effectively the tracklist — clicking one seeks playback to its start.
public struct StreamChapter: Codable, Sendable, Hashable, Identifiable {
    public var startSeconds: Double
    public var endSeconds: Double?
    public var title: String

    /// Stable identity for SwiftUI lists (chapters are ordered by start time).
    public var id: Double { startSeconds }

    public init(startSeconds: Double, endSeconds: Double? = nil, title: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
    }
}

/// A user-added radio/stream source. Persisted (via `StreamStore`) and rendered
/// across the sidebar, radio list, OLED, and inspector. The atomic unit of the
/// Radio / Streams feature — analogous to `LoadedTrack` for the library.
public struct StreamSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var channel: String
    public var kind: StreamKind
    /// 0–359 hue used to generate the cover poster (matches the v7 mockup, which
    /// never fetches real thumbnails — it tints a gradient by hue).
    public var hue: Int
    public var provider: StreamProvider
    public var addedAt: Date
    /// Live viewer count display string (e.g. "1.4K"); nil for non-live.
    public var viewers: String?
    /// Known duration in seconds for VOD; nil for live or unknown.
    public var durationSeconds: Double?
    /// Real cover thumbnail URL (fetched from yt-dlp/oEmbed); nil falls back to the
    /// hue poster and signals that metadata still needs fetching.
    public var thumbnailURL: String?
    /// YouTube chapters (a tracklist for long mixes); nil/empty = none.
    public var chapters: [StreamChapter]?
    /// Path of the offline copy made by Download for Offline; nil = none. The
    /// file is an ordinary library track, so it can move: `StreamStore.repointDownload`
    /// follows it, and `isDownloaded` also checks the file is really there, so a
    /// missed repoint reads as "not downloaded", never as a wrong file.
    public var downloadedPath: String?

    public init(
        id: String,
        url: String,
        title: String,
        channel: String,
        kind: StreamKind,
        hue: Int,
        provider: StreamProvider = .youtube,
        addedAt: Date,
        viewers: String? = nil,
        durationSeconds: Double? = nil,
        thumbnailURL: String? = nil,
        chapters: [StreamChapter]? = nil,
        downloadedPath: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.channel = channel
        self.kind = kind
        self.hue = hue
        self.provider = provider
        self.addedAt = addedAt
        self.viewers = viewers
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.chapters = chapters
        self.downloadedPath = downloadedPath
    }

    public var isLive: Bool { kind == .live }

    /// A downloaded stream is an offline copy: the path is set AND the file is
    /// still there. The file is an ordinary library track the user can rename,
    /// move, retag or delete outside the app, so a stale path degrades to "not
    /// downloaded" rather than pointing at the wrong file.
    public func isDownloaded(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let downloadedPath else { return false }
        return fileExists(downloadedPath)
    }

    /// Index of the chapter playing at `seconds`, or nil if no/empty chapters.
    public func chapterIndex(at seconds: Double) -> Int? {
        guard let chapters, !chapters.isEmpty else { return nil }
        var result: Int?
        for (i, chapter) in chapters.enumerated() where chapter.startSeconds <= seconds + 0.001 {
            result = i
        }
        return result ?? 0
    }
}
