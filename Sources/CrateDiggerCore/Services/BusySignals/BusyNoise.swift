import CoreGraphics
import Foundation

/// The sketch's small maths helpers (html:222–227), ported so the scenes can
/// be read side by side with the approved look.
///
/// `unit` is the one that matters. The sketch scatters things with a hash
/// rather than a random generator: which cells a secure read re-reads, how
/// tall each bar of a scan stands, where a dig turns up a find. Porting the
/// hash exactly (same constants, same order of operations) is what makes
/// those land where the sketch puts them, and keeps every frame a pure
/// function of its index, so two calls draw the same picture.
enum BusyNoise {
    /// A deterministic pseudo-random value in [0, 1) for index `i`:
    /// fract(sin(i · 127.1 + 311.7) · 43758.5453), exactly as html:222.
    ///
    /// A non-finite index reads as 0. The fractional part of a tiny negative
    /// product can round up to exactly 1 in floating point; that case also
    /// reads as 0, so the result honours its half-open range.
    static func unit(_ i: Double) -> Double {
        let x = sin(i * 127.1 + 311.7) * 43758.5453
        guard x.isFinite else { return 0 }
        let fraction = x - floor(x)
        return fraction < 1 ? fraction : 0
    }

    /// Linear interpolation from `a` (u = 0) to `b` (u = 1). Not clamped, as
    /// in the sketch: a scene that wants a clamp clamps `u` itself.
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ u: CGFloat) -> CGFloat {
        a + (b - a) * u
    }

    /// The point at angle `a` (radians, canvas convention: y-down, so a
    /// growing angle turns clockwise on screen) and distance `r` from
    /// (`cx`, `cy`).
    static func polar(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
    }

    /// A circle as a polyline of `segments` straight sides, for the places the
    /// sketch draws a disc as a path so it can be stroked with the rest of a
    /// shape. It returns `segments + 1` points, the last back at the first, so
    /// an open path still closes visually. Fewer than one segment is drawn as
    /// one.
    static func ring(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, segments: Int = 16) -> [CGPoint] {
        let n = max(1, segments)
        return (0...n).map { i in
            polar(cx, cy, r, Double(i) / Double(n) * 2 * .pi)
        }
    }
}
