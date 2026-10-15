import CoreGraphics
import Foundation

/// The pieces more than one Busy Signals scene draws, ported from the
/// sketch's shared glyphs (html:236-275) so each scene file can read line for
/// line beside its own `draw`.
///
/// Two families:
/// - **Picture glyphs** (`note`, `disc`), in 240 × 100 scene units. The rip
///   and the secure read both spin the same disc.
/// - **Mini glyphs** (`miniTrack`, `miniEndInk`), in 96 × 12 mini units. Every
///   mini is "source - - - - destination", and the dashes between are the
///   same eight in every one, so a glance along the rail compares progress
///   across jobs.
enum BusyGlyphs {
    // MARK: - Picture glyphs

    /// A note in flight (html:237-251): a single quaver with its flag
    /// (`kind` 0) or a beamed pair (any other `kind`), its head at (x, y).
    ///
    /// The sketch draws it under `translate(x, y)` + `scale(k)`. `BusyDrawing`
    /// carries no transforms, so the coordinates are mapped here before they
    /// are recorded. Canvas scaling thins strokes too, so the stems and beam
    /// carry `weight` = scale (the beam 2.2 × that); the flag's `quadCurve`
    /// has no weight and draws at the renderer's width, a difference of a
    /// fraction of a point at the one scale below 1 the rip uses (0.6).
    static func note(_ d: inout BusyDrawing, x: CGFloat, y: CGFloat, kind: Int,
                     ink: BusyInk, scale k: CGFloat = 1) {
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px * k, y: y + py * k) }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, weight: CGFloat) {
            let a = p(x1, y1), b = p(x2, y2)
            d.line(a.x, a.y, b.x, b.y, ink, weight: weight)
        }
        func head(_ px: CGFloat, _ py: CGFloat) {
            let c = p(px, py)
            d.ellipse(c.x, c.y, rx: 2.8 * k, ry: 2 * k, rotation: -0.35, ink)
        }

        head(0, 0)
        line(2.5, -0.5, 2.5, -10, weight: k)
        if kind == 0 {
            d.quadCurve(from: p(2.5, -10), control: p(7, -8), to: p(6, -4), ink)
        } else {
            head(6.5, 1.5)
            line(9, 1, 9, -8.5, weight: k)
            line(2.5, -10, 9, -8.5, weight: 2.2 * k)
        }
    }

    /// A CD seen from above (html:253-265): the rim, a dim inner rim, the
    /// clamp ring and the spindle hole, two pairs of dim groove arcs on
    /// opposite sides, and a hot index line that shows the spin. `angle` is
    /// in radians; everything that turns is offset from it.
    static func disc(_ d: inout BusyDrawing, cx: CGFloat, cy: CGFloat, radius r: CGFloat, angle: Double) {
        d.circle(cx, cy, r, .foreground)
        d.circle(cx, cy, r - 3, .dim)
        d.circle(cx, cy, 12, .foreground)
        d.circle(cx, cy, 3.4, .foreground)
        for offset in [0, Double.pi] {
            d.arc(cx, cy, r - 12, angle + offset + 0.55, angle + offset + 1.25, .dim)
            d.arc(cx, cy, r - 7, angle + offset + 0.7, angle + offset + 0.98, .dim)
        }
        let a = BusyNoise.polar(cx, cy, 5, angle), b = BusyNoise.polar(cx, cy, 11, angle)
        d.line(a.x, a.y, b.x, b.y, .hot)
    }

    // MARK: - Mini glyphs

    /// Dashes in the mini track, and where they sit on the 96-unit strip:
    /// between a source glyph ending before x 15.5 and a destination
    /// starting after 15.5 + 8 × 8.25 - 2.25 = 79.25.
    static let miniDashCount = 8
    static let miniTrackStart: CGFloat = 15.5
    static let miniDashWidth: CGFloat = 6
    static let miniDashGap: CGFloat = 2.25
    /// The strip's centre line, which every mini glyph is centred on.
    static let miniCentreY: CGFloat = 6

    /// The eight dashes between source and destination (html:268-273).
    ///
    /// - Lit: every dash once finished, else ⌊fraction × 8⌋ (none while the
    ///   total is unknown), in cool; the rest dim.
    /// - While running, a hot packet walks one dash per 8 fps step, so even
    ///   an indeterminate job visibly moves. It stops once finished: the
    ///   destination's blink takes over calling for attention.
    static func miniTrack(_ d: inout BusyDrawing, _ input: BusySceneInput) {
        let n = miniDashCount
        let lit = input.isFinished ? n : Int(((input.progress.fraction ?? 0) * Double(n)).rounded(.down))
        func x(_ i: Int) -> CGFloat { miniTrackStart + CGFloat(i) * (miniDashWidth + miniDashGap) }
        for i in 0..<n {
            d.line(x(i), miniCentreY, x(i) + miniDashWidth, miniCentreY, i < lit ? .cool : .dim)
        }
        if !input.isFinished {
            let packet = x(input.step % n)
            d.line(packet, miniCentreY, packet + miniDashWidth, miniCentreY, .hot)
        }
    }

    /// The destination glyph's ink (html:275): steady foreground while the
    /// job runs, hot on the lit half of the blink once it has finished. The
    /// ledger holds `markLit` steady on under Reduce Motion, so an unseen
    /// finished mini then reads steady hot.
    static func miniEndInk(_ input: BusySceneInput) -> BusyInk {
        input.isFinished && input.markLit ? .hot : .foreground
    }
}
