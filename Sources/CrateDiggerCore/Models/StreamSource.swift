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

    /// Display name shown in the sidebar.
    public var title: String {
        switch self {
        case .youtubeLive:    return "YT Live"
        case .youtubeRecords: return "YT Records"
        }
    }

    /// SF Symbol for the sidebar row.
    public var iconName: String {
        switch self {
        case .youtubeLive:    return "antenna.radiowaves.left.and.right"
        case .youtubeRecords: return "waveform"
        }
    }

    /// The category a stream falls into.
    public static func of(_ stream: StreamSource) -> RadioCategory {
        switch stream.provider {
        case .youtube: return stream.isLive ? .youtubeLive : .youtubeRecords
        }
    }

    /// Whether a stream belongs to this category.
    public func contains(_ stream: StreamSource) -> Bool {
        RadioCategory.of(stream) == self
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
        chapters: [StreamChapter]? = nil
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
    }

    public var isLive: Bool { kind == .live }

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
