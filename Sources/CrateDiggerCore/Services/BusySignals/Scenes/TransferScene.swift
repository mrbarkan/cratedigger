import CoreGraphics
import Foundation

/// The device transfer: a laptop feeding an iPod whose screen shows the
/// no-entry sign until it is done (html:729-771).
///
/// Ported line for line from the sketch's `draw` and its `MINI.laptop` /
/// `MINI.ipod`, with the user's simplifications of the iPod kept intact:
/// - **Picture:** the body is an outline, the screen holds only Apple's
///   no-entry "do not disconnect" sign (a blinking check once done), and the
///   click wheel is two bare circles. No menu text, no wheel glyphs.
/// - **Mini:** an outline in the destination ink, a solid screen and a solid
///   wheel, so it reads at 12 pt.
///
/// Everything that moves (the lit library row, the packets on the cable) runs
/// off the clock, `input.time`, which the ledger freezes at the finish; once
/// finished the row goes dim and the packets stop, so the frozen time never
/// shows.
enum TransferScene {
    // MARK: - Geometry (scene units, from html:745-769)

    /// The cable's quadratic Bézier: from the laptop's base, sagging through
    /// `cableControl`, up to the foot of the iPod.
    static let cableStart = CGPoint(x: 84, y: 65)
    static let cableControl = CGPoint(x: 126, y: 108)
    static let cableEnd = CGPoint(x: 186, y: 89)
    /// Dot intervals along the cable; there are `cableSteps + 1` dots.
    static let cableSteps = 18
    /// Packets on the cable at once, spaced this many dots apart.
    static let packetCount = 3
    static let packetSpacing = 6
    /// Library rows on the laptop screen, and how long each stays lit.
    static let rowCount = 5
    static let rowPeriod: TimeInterval = 0.6
    /// The no-entry sign on the iPod screen.
    static let signCentre = CGPoint(x: 186, y: 29)
    static let signRadius: CGFloat = 8

    /// Any frame reads as a transfer: the sign is drawn whatever the clock,
    /// and at 0 one row is lit and the three packets sit evenly along the
    /// cable.
    static let keyTime: TimeInterval = 0

    // MARK: - Picture

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let running = !input.isFinished

        // The laptop: lid, a dim screen bezel, and the library rows, one of
        // them lit (the row being sent) while running.
        d.roundedRect(10, 22, 64, 40, 2, .foreground, fill: .background)
        d.rect(14, 26, 56, 32, .dim)
        let row = litRow(at: input.time)
        for i in 0..<rowCount {
            let y = 31 + CGFloat(i) * 5.5
            let length = 22 + CGFloat(BusyNoise.unit(Double(i + 3))) * 24
            d.line(18, y, 18 + length, y, running && i == row ? .cool : .dim)
        }
        d.poly([CGPoint(x: 6, y: 62), CGPoint(x: 78, y: 62), CGPoint(x: 84, y: 67), CGPoint(x: 0, y: 67)],
               .foreground, closed: true)

        // The cable as a dotted curve, with packets hopping one dot per step.
        for i in 0...cableSteps {
            let p = cablePoint(Double(i) / Double(cableSteps))
            d.dot(p.x, p.y, 0.8, .dim)
        }
        if running {
            for j in 0..<packetCount {
                let i = (input.step + j * packetSpacing) % (cableSteps + 1)
                let p = cablePoint(Double(i) / Double(cableSteps))
                d.block(p.x - 1.6, p.y - 1.6, 3.2, 3.2, .cool)
            }
        }

        // iPod classic, pared back: body, a screen holding only the sign
        // (a check once done), and a bare click wheel.
        d.roundedRect(163, 11, 46, 77, 5, .foreground, fill: .background)
        d.roundedRect(167, 15, 38, 28, 1.5, .foreground)
        if running {
            d.circle(signCentre.x, signCentre.y, signRadius, .hot)
            let a = BusyNoise.polar(signCentre.x, signCentre.y, signRadius, -Double.pi * 3 / 4)
            let b = BusyNoise.polar(signCentre.x, signCentre.y, signRadius, Double.pi / 4)
            d.line(a.x, a.y, b.x, b.y, .hot)
        } else if input.markLit {
            d.poly([CGPoint(x: 180, y: 29), CGPoint(x: 184.5, y: 33.5), CGPoint(x: 193, y: 24)], .hot)
        }
        d.circle(186, 64, 16, .foreground)
        d.circle(186, 64, 5.5, .foreground)
        return d
    }

    /// The library row lit at `time`: a new one every `rowPeriod`, wrapping
    /// after `rowCount`. The sketch's local clock is never negative, but this
    /// one is any `TimeInterval`, so a negative, non-finite or huge time reads
    /// as row 0 (or wraps in floating point) instead of giving a negative
    /// remainder that lights nothing, or trapping on the `Int` conversion.
    static func litRow(at time: TimeInterval) -> Int {
        guard time.isFinite, time > 0 else { return 0 }
        let period = (time / rowPeriod).rounded(.down)
        return Int(period.truncatingRemainder(dividingBy: Double(rowCount)))
    }

    /// The point at `u` (0…1) along the cable's quadratic Bézier.
    static func cablePoint(_ u: Double) -> CGPoint {
        let u = CGFloat(u), v = 1 - u
        let a = cableStart, c = cableControl, b = cableEnd
        return CGPoint(x: v * v * a.x + 2 * v * u * c.x + u * u * b.x,
                       y: v * v * a.y + 2 * v * u * c.y + u * u * b.y)
    }

    // MARK: - Mini

    /// Laptop, the shared dashed track, iPod (html:744).
    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        miniLaptop(&d, x: 1)
        BusyGlyphs.miniTrack(&d, input)
        miniIPod(&d, x: 85, ink: BusyGlyphs.miniEndInk(input))
        return d
    }

    /// `MINI.laptop` (html:323): a lid and a base.
    static func miniLaptop(_ d: inout BusyDrawing, x: CGFloat) {
        d.rect(x + 1, 1.8, 8.4, 5.8, .foreground)
        d.poly([CGPoint(x: x + 1, y: 7.6), CGPoint(x: x + 9.4, y: 7.6),
                CGPoint(x: x + 10.6, y: 9.4), CGPoint(x: x - 0.2, y: 9.4)],
               .foreground, closed: true)
    }

    /// `MINI.ipod` (html:324-328): the body outline in the destination ink, a
    /// solid screen and a solid click wheel.
    static func miniIPod(_ d: inout BusyDrawing, x: CGFloat, ink: BusyInk) {
        d.roundedRect(x + 1.6, 0.6, 7.4, 10.8, 1.8, ink)
        d.block(x + 3, 2, 4.6, 2.8, .foreground)
        d.dot(x + 5.3, 7.9, 2, .foreground)
    }
}
