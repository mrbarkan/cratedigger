import Foundation

/// The clock every Busy Signals scene reads.
///
/// Scenes are stateless functions of their input, so time is the only thing
/// that moves them, and it moves on an 8 fps grid: every time input is
/// floored to a multiple of 1/8 s before a scene sees it. Two dates inside one
/// step therefore give equal inputs and equal drawings, and the App's
/// `Equatable` canvas redraws nothing for them. That, not a slower timer, is
/// what keeps the picture cheap: the view may ask twice a step and pay once.
///
/// Degenerate time (NaN, infinite, negative, or too large to count in steps)
/// reads as 0 everywhere, so a bad date upstream draws the first frame rather
/// than trapping on an `Int` conversion or drawing garbage.
public enum BusySignalTiming {
    /// The step rate the sketch was approved at. Motion is stepped on purpose:
    /// it reads as hardware ticking over, not as an animation curve.
    public static let framesPerSecond: Double = 8

    /// How long a finished picture blinks once you are looking at it, counted
    /// from when the job finished or when its screen came up, whichever is
    /// later. After that it holds steady and its timeline pauses.
    static let pictureBlinkDuration: TimeInterval = 8

    /// How long a finished job's screen must be on the glass for the job to
    /// count as seen, and its rail mini to stop calling for attention.
    static let seenAfter: TimeInterval = 1.5

    /// `t` floored to the 8 fps grid: floor(t × 8) / 8.
    public static func quantized(_ t: TimeInterval) -> TimeInterval {
        Double(step(t)) / framesPerSecond
    }

    /// Which 8 fps step `t` falls in: floor(t × 8). Scenes use it where the
    /// sketch counts frames (a stepping head, a re-read cell's turn).
    public static func step(_ t: TimeInterval) -> Int {
        // `sanitized` bounds t · 8 below 2^63, so this conversion cannot trap.
        Int((sanitized(t) * framesPerSecond).rounded(.down))
    }

    /// The sketch's blink (html:234): lit while floor(t × hz) is even, so it
    /// starts lit at t = 0 and toggles every 1/hz s: every half second at the
    /// default 2 Hz, so one full on/off cycle per second. A non-positive or non-finite rate holds it lit.
    public static func blink(_ t: TimeInterval, hz: Double = 2) -> Bool {
        guard hz.isFinite, hz > 0 else { return true }
        let phase = (sanitized(t) * hz).rounded(.down)
        guard phase.isFinite else { return true }
        return phase.truncatingRemainder(dividingBy: 2) == 0
    }

    /// `t` if it can be counted in 8 fps steps, else 0. The upper bound keeps
    /// floor(t × 8) below 2^63 so `step` can convert it to `Int`.
    private static func sanitized(_ t: TimeInterval) -> TimeInterval {
        guard t.isFinite, t > 0, t < Double(Int.max) / framesPerSecond else { return 0 }
        return t
    }
}
