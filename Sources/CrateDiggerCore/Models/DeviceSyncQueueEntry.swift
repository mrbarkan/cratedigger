import Foundation

/// One track waiting to be synced onto an external device: what to put where.
/// The staging tree mirrors the device layout, so a baked entry's local file is
/// always `<staging dir>/<destinationRelativePath>` — no second path field.
public struct DeviceSyncQueueEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The queued track (source file + editable tags). Artwork rides along by
    /// hash, not bytes, so persisted queues stay small.
    public var track: LoadedTrack
    /// Path relative to the device *mount root* (includes the profile's music
    /// subpath, e.g. "Music/Artist/2001 Album/01 Song.m4a").
    public var destinationRelativePath: String
    /// true = a pre-baked conversion exists in the staging tree. false =
    /// copy-mode: sync copies the original source file directly, nothing is
    /// ever staged locally.
    public var isStaged: Bool
    /// Source file mtime captured at bake time — the staleness guard.
    public var sourceModifiedAt: Date
    public var queuedAt: Date
    /// What the user chose for this track's album when it was queued against a
    /// device copy that differs. nil: no decision recorded (a new album, or a
    /// queue saved before decisions existed), so SYNC asks if the device
    /// turns out to hold a differing copy.
    public var decision: DeviceAlbumDecision?
    /// The kind of difference `decision` answered. nil when none was
    /// recorded (no decision, or a queue saved before kinds were); a
    /// decision without one is asked again at SYNC.
    public var decisionKind: DeviceDifferenceKind?

    public init(
        id: UUID = UUID(),
        track: LoadedTrack,
        destinationRelativePath: String,
        isStaged: Bool,
        sourceModifiedAt: Date,
        queuedAt: Date = Date(),
        decision: DeviceAlbumDecision? = nil,
        decisionKind: DeviceDifferenceKind? = nil
    ) {
        self.id = id
        self.track = track
        self.destinationRelativePath = destinationRelativePath
        self.isStaged = isStaged
        self.sourceModifiedAt = sourceModifiedAt
        self.queuedAt = queuedAt
        self.decision = decision
        self.decisionKind = decisionKind
    }

    /// The stored answer with its kind, nil when none was recorded.
    public var storedDecision: DeviceStoredDecision? {
        decision.map { DeviceStoredDecision($0, for: decisionKind) }
    }
}
