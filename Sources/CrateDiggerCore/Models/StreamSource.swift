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
        durationSeconds: Double? = nil
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
    }

    public var isLive: Bool { kind == .live }
}
