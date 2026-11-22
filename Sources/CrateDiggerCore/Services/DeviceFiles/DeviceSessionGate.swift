import Foundation

/// What started a device session.
public enum DeviceSessionTrigger: Sendable, Hashable {
    /// The device appeared. Only reads may follow (spec invariant I6).
    case mount
    /// The user pressed for it: a transfer, a cleanup, an import.
    case userAction
}

/// Something a session may do to or with a device.
public enum DeviceAction: Sendable, Hashable, CaseIterable {
    case probe, transferAudio, sweep, writeExtras, importPlays, scrobble
}

/// Which actions a session may take, by what started it and whether the
/// device was matched by volume UUID (spec invariant I6). Mounting probes
/// and nothing else. A user action may transfer audio and sweep for any
/// matched profile, as transfers always have; pictures, playlists, lyrics,
/// play import and scrobbling also need the UUID match, because a profile
/// matched only by name or mount path could be another iPod.
public enum DeviceSessionGate {
    public static func allows(_ action: DeviceAction, trigger: DeviceSessionTrigger, matchedByUUID: Bool) -> Bool {
        switch trigger {
        case .mount:
            return action == .probe
        case .userAction:
            switch action {
            case .probe, .transferAudio, .sweep: return true
            case .writeExtras, .importPlays, .scrobble: return matchedByUUID
            }
        }
    }
}
