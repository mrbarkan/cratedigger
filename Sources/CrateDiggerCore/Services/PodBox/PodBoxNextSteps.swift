import Foundation

/// What a device session changed, so the summary can say what to do next.
public struct DeviceWriteChanges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let audio = DeviceWriteChanges(rawValue: 1 << 0)
    public static let covers = DeviceWriteChanges(rawValue: 1 << 1)
    public static let pictures = DeviceWriteChanges(rawValue: 1 << 2)
    public static let lyrics = DeviceWriteChanges(rawValue: 1 << 3)
    public static let playlists = DeviceWriteChanges(rawValue: 1 << 4)
    public static let cleanup = DeviceWriteChanges(rawValue: 1 << 5)
    public static let knownArtists = DeviceWriteChanges(rawValue: 1 << 6)
}

/// The steps left for the user on the iPod after CrateDigger wrote to it.
/// PodBox only picks up new files when it scans, and only redraws pictures
/// when its art cache is rebuilt, so a finished transfer has to say so.
public enum PodBoxNextSteps {
    static let ejectAndUpdate = "Eject the iPod. PodBox adds the new music when it restarts. If it does not appear: Settings ▸ Library ▸ Maintenance ▸ Update Database."
    static let ejectOnly = "Eject the iPod."
    static let updateArtCache = "Then on the iPod: Settings ▸ Library ▸ Maintenance ▸ Update Art Cache."
    static let unreadableClears = "The unreadable-files list clears at the next scan."
    static let soundAnalysis = "Update Sound Analysis measures the new tracks."
    static let ejectDevice = "Eject the device before unplugging."

    /// Lines in reading order. PodBox: new music or playlists, then pictures,
    /// then cleanup, then sound analysis when the playlist engine is on and
    /// tracks were added. Lyrics alone (and known artists alone) give no
    /// line. Any other firmware, or none known: one line.
    public static func after(_ changes: DeviceWriteChanges, firmware: DeviceFirmware?) -> [String] {
        guard !changes.isEmpty else { return [] }
        guard let firmware, firmware.flavour == .podBox else { return [ejectDevice] }

        var lines: [String] = []
        let pictures = !changes.isDisjoint(with: [.covers, .pictures])
        if !changes.isDisjoint(with: [.audio, .playlists]) {
            lines.append(ejectAndUpdate)
        } else if pictures {
            lines.append(ejectOnly)
        }
        if pictures { lines.append(updateArtCache) }
        if changes.contains(.cleanup) { lines.append(unreadableClears) }
        if changes.contains(.audio), firmware.config.value("playlist engine")?.lowercased() == "on" {
            lines.append(soundAnalysis)
        }
        return lines
    }

    /// What CrateDigger noted when it last changed art on an iPod: when, and
    /// what the player's stamp file looked like then, so the reminder to
    /// rebuild the art cache can tell when the player has done it.
    public struct ArtCacheMark: Codable, Equatable, Sendable {
        public var wroteAt: Date
        /// The stamp's modification date at the write; nil when it was not there.
        public var stampAtWrite: Date?
        /// False for a mark saved before the stamp was recorded: only its date is known.
        public var recordedStamp: Bool

        public init(wroteAt: Date, stampAtWrite: Date?, recordedStamp: Bool = true) {
            self.wroteAt = wroteAt
            self.stampAtWrite = stampAtWrite
            self.recordedStamp = recordedStamp
        }
    }

    /// The player has rebuilt its art cache when its stamp file is there and
    /// differs in any way from what it was at our write. Only the iPod's own
    /// clock is compared with itself, so an iPod whose clock was never set
    /// (it stamps 2000 or 1970) still clears the reminder. A mark saved
    /// before the stamp was recorded falls back to the date rule.
    public static func isDone(_ mark: ArtCacheMark?, stampNow: Date?) -> Bool {
        guard let mark, let stampNow else { return false }
        guard mark.recordedStamp else { return isDone(lastWrite: mark.wroteAt, playerFileModified: stampNow) }
        return stampNow != mark.stampAtWrite
    }

    /// The old rule, for a mark with no recorded stamp: the file the player
    /// rewrites is newer than our write by more than a minute (FAT keeps
    /// times to 2 seconds, and the two clocks are not the same clock).
    public static func isDone(lastWrite: Date?, playerFileModified: Date?) -> Bool {
        guard let lastWrite, let playerFileModified else { return false }
        return playerFileModified > lastWrite.addingTimeInterval(60)
    }
}
