import Foundation

/// Menu commands that behave differently in the compact player. Everything
/// not listed here works the same in both layouts — playback above all.
public enum PlayerCommand: CaseIterable, Sendable {
    case find
    case goToCurrentSong
    case selectDisplay
    case revealSelection
    case convertSelected
    case transferToDevice
    case playNextSelection
    case playLastSelection
    case rate
}

public enum CommandAvailability: Sendable, Equatable {
    case available
    /// Asking for it is asking for the full window: expand, then run.
    case expandsFirst
    /// Acts on a browser selection the compact player cannot show.
    case disabled
}

public enum CompactCommandPolicy {
    public static func availability(_ command: PlayerCommand, in layout: PlayerLayout) -> CommandAvailability {
        guard layout == .compact else { return .available }
        switch command {
        case .find, .goToCurrentSong, .selectDisplay:
            return .expandsFirst
        case .revealSelection, .convertSelected, .transferToDevice,
             .playNextSelection, .playLastSelection, .rate:
            return .disabled
        }
    }
}
