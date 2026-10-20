import Foundation

/// Quick EQ: with it switched on in the equalizer, pointing at a fader
/// selects it and the keyboard moves it — ↑/↓, or W/S for the left hand —
/// and ←/→ (A/D) hand the keys to the fader beside it.
/// This is the part of that which is a decision rather than wiring: which key
/// means what, where a nudge lands and which fader is next.
public enum QuickEQ {
    public enum Direction: Equatable, Sendable { case up, down }

    /// What a Quick EQ key asks for.
    public enum Action: Equatable, Sendable {
        /// Move the selected fader one step.
        case nudge(Direction)
        /// Select the fader this many places to the right (negative: left).
        case select(offset: Int)
    }

    /// One press moves a fader by the same 0.5 dB a drag snaps to, so the
    /// two never disagree about where a fader can sit.
    public static let step = 0.5

    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126

    /// The action a key press asks for, or nil when it isn't a Quick EQ key.
    ///
    /// - Parameters:
    ///   - keyCode: the hardware key code, which is how the arrows are known.
    ///   - characters: the typed characters ignoring modifiers. W, A, S and D
    ///     are matched as letters, not key positions, so they follow the layout.
    ///   - hasCommandModifier: ⌘, ⌃ or ⌥ is held. Those keys belong to menus
    ///     and the system (⌘W closes the window), so Quick EQ lets them pass.
    ///     Shift is fine: it is how a held Caps Lock or a capital W arrives.
    public static func action(keyCode: UInt16,
                              characters: String?,
                              hasCommandModifier: Bool) -> Action? {
        guard !hasCommandModifier else { return nil }
        switch keyCode {
        case upArrowKeyCode:    return .nudge(.up)
        case downArrowKeyCode:  return .nudge(.down)
        case leftArrowKeyCode:  return .select(offset: -1)
        case rightArrowKeyCode: return .select(offset: 1)
        default: break
        }
        switch characters?.lowercased() {
        case "w": return .nudge(.up)
        case "s": return .nudge(.down)
        case "a": return .select(offset: -1)
        case "d": return .select(offset: 1)
        default:  return nil
        }
    }

    /// The fader `offset` places from `band`, stopping at the first and last
    /// rather than wrapping, so holding a key runs into the end of the bank
    /// instead of jumping across it.
    public static func band(_ band: Int, offsetBy offset: Int, count: Int) -> Int {
        min(max(band + offset, 0), count - 1)
    }

    /// `gain` moved one step, snapped onto the 0.5 dB grid and kept inside
    /// the faders' travel. A gain that is off the grid (an imported curve can
    /// be) lands on the next grid point in the direction asked for.
    public static func nudged(_ gain: Double,
                              _ direction: Direction,
                              in range: ClosedRange<Double>) -> Double {
        let gridPosition = gain / step
        let next: Double
        switch direction {
        case .up:   next = (gridPosition + 1e-9).rounded(.down) + 1
        case .down: next = (gridPosition - 1e-9).rounded(.up) - 1
        }
        return min(max(next * step, range.lowerBound), range.upperBound)
    }
}
