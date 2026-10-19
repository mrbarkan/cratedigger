import Foundation

/// Quick EQ: with it switched on in the equalizer, pointing at a fader
/// selects it and the keyboard moves it — ↑/↓, or W/S for the left hand.
/// This is the part of that which is a decision rather than wiring: which key
/// means which way, and where a nudge lands.
public enum QuickEQ {
    public enum Direction: Equatable, Sendable { case up, down }

    /// One press moves a fader by the same 0.5 dB a drag snaps to, so the
    /// two never disagree about where a fader can sit.
    public static let step = 0.5

    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    /// The direction a key press asks for, or nil when it isn't a Quick EQ key.
    ///
    /// - Parameters:
    ///   - keyCode: the hardware key code, which is how the arrows are known.
    ///   - characters: the typed characters ignoring modifiers. W and S are
    ///     matched as letters, not key positions, so they follow the layout.
    ///   - hasCommandModifier: ⌘, ⌃ or ⌥ is held. Those keys belong to menus
    ///     and the system (⌘W closes the window), so Quick EQ lets them pass.
    ///     Shift is fine: it is how a held Caps Lock or a capital W arrives.
    public static func direction(keyCode: UInt16,
                                 characters: String?,
                                 hasCommandModifier: Bool) -> Direction? {
        guard !hasCommandModifier else { return nil }
        switch keyCode {
        case upArrowKeyCode:   return .up
        case downArrowKeyCode: return .down
        default: break
        }
        switch characters?.lowercased() {
        case "w": return .up
        case "s": return .down
        default:  return nil
        }
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
