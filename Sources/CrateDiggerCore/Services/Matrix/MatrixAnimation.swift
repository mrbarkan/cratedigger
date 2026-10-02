import Foundation

/// Something that turns audio into pictures on the NOW screen's matrix.
///
/// This is the seam a user-made animation would plug into one day: it hears a
/// `MatrixInput` per tick and answers with a whole frame, heat included, so
/// the view never needs to know which animation is running.
public protocol MatrixAnimation: Sendable {
    mutating func frame(for input: MatrixInput) -> MatrixFrame
    /// True when nothing is moving and the last frame was dark, so the
    /// driver may stop its timer.
    var isAtRest: Bool { get }
    /// The heat a cell has when it lights, which is also the tint of its
    /// faint print while it is dark. Asked of the animation rather than read
    /// off the frame because an unlit cell's heat stays 0 (see `MatrixFrame`),
    /// and without this the dark grid would print in one flat colour whatever
    /// direction the animation runs.
    static func restingHeat(column: Int, row: Int) -> Double
}

/// The animations the titlebar status LED steps through, in click order.
public enum MatrixAnimationKind: String, CaseIterable, Sendable {
    case vertical, horizontal, explosions, frame, off

    /// The click order: Vertical → Horizontal → Explosions → Frame → Off → Vertical.
    public var next: MatrixAnimationKind {
        switch self {
        case .vertical: return .horizontal
        case .horizontal: return .explosions
        case .explosions: return .frame
        case .frame: return .off
        case .off: return .vertical
        }
    }

    public var label: String {
        switch self {
        case .vertical: return "Vertical VU"
        case .horizontal: return "Horizontal VU"
        case .explosions: return "Explosions"
        case .frame: return "Frame"
        case .off: return "Off"
        }
    }

    /// A fresh animation for this kind, or nil for `.off`, where no matrix is
    /// drawn and so nothing should tick.
    public func make() -> (any MatrixAnimation)? {
        switch self {
        case .vertical: return VerticalVUAnimation()
        case .horizontal: return HorizontalVUAnimation()
        case .explosions: return ExplosionsAnimation()
        case .frame: return FrameAnimation()
        case .off: return nil
        }
    }

    /// The tint of a dark cell's print under this kind: its animation's
    /// `restingHeat`. `.off` draws no matrix, so its answer is never seen.
    public func restingHeat(column: Int, row: Int) -> Double {
        switch self {
        case .vertical: return VerticalVUAnimation.restingHeat(column: column, row: row)
        case .horizontal: return HorizontalVUAnimation.restingHeat(column: column, row: row)
        case .explosions: return ExplosionsAnimation.restingHeat(column: column, row: row)
        case .frame: return FrameAnimation.restingHeat(column: column, row: row)
        case .off: return 0
        }
    }

    /// A saved value this build no longer knows (a removed or future user
    /// animation) falls back to Vertical VU, which keeps the screen working
    /// rather than blank.
    public init(persisted: String?) {
        self = persisted.flatMap(Self.init(rawValue:)) ?? .vertical
    }
}
