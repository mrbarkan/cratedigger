import CoreGraphics
import Foundation

/// The Secure Mode read (html:393-449): a laser sled walks across the current
/// track's band on the disc, once per pass, while a 60-cell sector map beside
/// it fills as outlines on pass 1 and solid on pass 2. Doubtful sectors light
/// a few cells hot during the re-read.
///
/// Ported from the sketch's `draw` line for line; what the sketch simulated
/// comes from the engine's own report (`BusySecureRead`, spec §3.2):
///
/// | Sketch | Here |
/// |---|---|
/// | `s.k`, `s.total` | `trackOrdinal − 1`, `trackCount` |
/// | `s.pass` | 1 on `.pass1`, 2 otherwise |
/// | `s.pp` | `phaseFraction`, in every phase |
/// | `rnd(k·100 + i) < 0.05` hot cells | `.retry` only, at most six (below) |
///
/// The engine reports `rereads: 0` through both passes and counts attempts,
/// not cells, during `.retry`, so pass 1 and pass 2 never draw a hot cell,
/// and `.retry` draws the map full with `min(rereads, 6)` cells hot, taken in
/// the sketch's hash order so they land where its orange cells would.
enum SecureReadScene {
    // MARK: Geometry (html:427-437)

    static let discCentre = CGPoint(x: 52, y: 50)
    static let discRadius: CGFloat = 38
    /// The band rings span from just outside the clamp ring to inside the rim.
    static let bandInner: CGFloat = 13
    static let bandSpan: CGFloat = 23
    /// More rings than this would merge into a grey disc; a long disc's
    /// tracks share bands instead.
    static let maxBands = 12
    /// The sled's rail runs out to x 146, where an end stop stands.
    static let railEnd: CGFloat = 146

    static let mapColumns = 10, mapRows = 6
    static let cellSize: CGFloat = 6, cellGap: CGFloat = 1.6
    static let mapOrigin = CGPoint(x: 158, y: 24)
    static var cellCount: Int { mapColumns * mapRows }
    /// A tenth of the map: about the sketch's density of orange (≈ 5 %), so
    /// a bad sector reads as a few hot cells, never a map flooded orange.
    static let maxHotCells = 6

    /// The spindle's index tick turns at this many radians a second.
    static let spindleSpeed = 6.2

    /// 0: the sled's position comes from progress, not the clock, so the
    /// still frame is already an honest picture of where the read is.
    static let keyTime: TimeInterval = 0

    // MARK: Picture

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let read = Read(input.progress)
        let done = input.isFinished
        let cx = discCentre.x, cy = discCentre.y

        // The disc, and its index tick turning with the clock (frozen with
        // `time` at the finish).
        let angle = input.time * spindleSpeed
        d.circle(cx, cy, discRadius, .foreground)
        d.circle(cx, cy, 11, .foreground)
        d.circle(cx, cy, 3.4, .foreground)

        let bands = min(read.count, maxBands)
        func rk(_ j: Int) -> CGFloat { bandInner + bandSpan * CGFloat(j) / CGFloat(bands) }
        for j in 1..<max(bands, 1) { d.circle(cx, cy, rk(j), .dim) }
        // Track k sits in band ⌊k × bands / count⌋, so a disc longer than
        // twelve tracks walks each band more than once.
        let band = read.k * bands / read.count
        if !done {
            d.circle(cx, cy, rk(band), .cool)
            d.circle(cx, cy, rk(band + 1), .cool)
        }
        let a = BusyNoise.polar(cx, cy, 5, angle), b = BusyNoise.polar(cx, cy, 10, angle)
        d.line(a.x, a.y, b.x, b.y, .hot)

        // The sled on its rail.
        d.line(cx + 10, cy, railEnd, cy, .dim)
        d.line(railEnd, cy - 6, railEnd, cy + 6, .foreground)
        let rr = done ? rk(0) : BusyNoise.lerp(rk(band), rk(band + 1), CGFloat(read.fraction))
        let sx = cx + rr
        d.rect(sx - 3, cy - 5, 6, 10, .foreground, fill: .background)
        if !done && input.step % 2 == 0 { d.dot(sx, cy, 1.3, .hot) }
        if !done { d.text(read.sledLabel, sx, cy - 8, .cool, size: 6, align: .center) }

        // The sector map.
        let x0 = mapOrigin.x, y0 = mapOrigin.y, cs = cellSize
        let filled = done || read.phase == .retry ? cellCount : Int((read.fraction * Double(cellCount)).rounded(.down))
        let hot = done ? [] : hotCells(read)
        d.text(done ? "ALL TRACKS" : read.header, x0, y0 - 6, .dim, size: 6)
        for i in 0..<cellCount {
            let x = x0 + CGFloat(i % mapColumns) * (cs + cellGap)
            let y = y0 + CGFloat(i / mapColumns) * (cs + cellGap)
            if done { d.block(x, y, cs, cs, .cool); continue }
            if i >= filled { d.dot(x + cs / 2, y + cs / 2, 0.6, .dim); continue }
            if read.phase == .pass1 {
                d.rect(x + 0.5, y + 0.5, cs - 1, cs - 1, .cool)
            } else {
                d.block(x, y, cs, cs, hot.contains(i) ? .hot : .cool)
            }
        }
        if done && input.markLit {
            d.text("OK", x0 + 34, y0 + 64, .hot, size: 8, align: .center)
        }
        return d
    }

    /// The cells drawn hot: none outside `.retry`; inside it, the first
    /// `min(rereads, 6)` cells in order of the sketch's hash for this track,
    /// `BusyNoise.unit(k·100 + i)` ascending (html:444).
    static func hotCells(_ read: Read) -> Set<Int> {
        guard read.phase == .retry else { return [] }
        let count = min(max(read.rereads, 0), maxHotCells)
        guard count > 0 else { return [] }
        let base = Double(read.k * 100)
        func noise(_ i: Int) -> Double { BusyNoise.unit(base + Double(i)) }
        let order = (0..<cellCount).sorted { (a: Int, b: Int) -> Bool in noise(a) < noise(b) }
        return Set(order.prefix(count))
    }

    // MARK: Mini (html:419)

    /// Disc - - - - sector grid. The grid fills a quarter per quarter of the
    /// phase, and once finished all four blink hot.
    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        let read = Read(input.progress)
        miniDisc(&d, cx: 6, input)
        BusyGlyphs.miniTrack(&d, input)
        let n = input.isFinished ? 4 : Int((read.fraction * 4).rounded(.down))
        miniGrid(&d, x: 86, filled: n, BusyGlyphs.miniEndInk(input))
        return d
    }

    /// `MINI.disc` (html:276-281): a rim, a hub dot and a hot index that
    /// turns 30° a step, parked at 0 once finished. `RipScene` draws the same
    /// glyph; once both scenes have landed, move this into `BusyGlyphs` and
    /// have both call it.
    static func miniDisc(_ d: inout BusyDrawing, cx: CGFloat, _ input: BusySceneInput) {
        let y = BusyGlyphs.miniCentreY
        d.circle(cx, y, 4.6, .foreground)
        d.dot(cx, y, 0.8, .foreground)
        let a = Double(input.isFinished ? 0 : input.step) * .pi / 6
        let p1 = BusyNoise.polar(cx, y, 1.8, a), p2 = BusyNoise.polar(cx, y, 4, a)
        d.line(p1.x, p1.y, p2.x, p2.y, .hot)
    }

    /// `MINI.grid` (html:286-291): four cells, two by two. Filled cells take
    /// the destination ink, except that the steady foreground reads cool so
    /// the grid matches the picture's map; empty cells are dim outlines.
    static func miniGrid(_ d: inout BusyDrawing, x: CGFloat, filled n: Int, _ ink: BusyInk) {
        for i in 0..<4 {
            let gx = x + CGFloat(i % 2) * 4.8
            let gy = 1.6 + CGFloat(i / 2) * 4.8
            if i < n {
                d.block(gx, gy, 3.6, 3.6, ink == .foreground ? .cool : ink)
            } else {
                d.rect(gx + 0.3, gy + 0.3, 3, 3, .dim)
            }
        }
    }

    // MARK: Reading the progress

    /// The engine's report, made safe to draw from. Before the first report
    /// arrives (the ledger can begin a read a moment before the engine posts)
    /// it reads as the start of pass 1 on track 1 of the job's count.
    struct Read: Equatable {
        /// 0-based track, clamped into `0..<count`.
        var k: Int
        /// At least 1.
        var count: Int
        var phase: SecureRipEngine.Phase
        /// 0…1 within the phase.
        var fraction: Double
        var rereads: Int

        init(_ progress: BusyProgress) {
            if let secure = progress.secure {
                count = max(secure.trackCount, 1)
                k = min(max(secure.trackOrdinal - 1, 0), count - 1)
                phase = secure.phase
                fraction = secure.phaseFraction
                rereads = secure.rereads
            } else {
                count = max(progress.total ?? 1, 1)
                k = min(progress.completed, count - 1)
                phase = .pass1
                fraction = 0
                rereads = 0
            }
        }

        var pass: Int { phase == .pass1 ? 1 : 2 }

        /// "P1", "P2", or "RE" while doubtful sectors are re-read.
        var sledLabel: String { phase == .retry ? "RE" : "P\(pass)" }

        /// "TRK 03 · PASS 2", or "TRK 03 · RE-READ".
        var header: String {
            let track = String(format: "%02d", k + 1)
            return phase == .retry ? "TRK \(track) · RE-READ" : "TRK \(track) · PASS \(pass)"
        }
    }
}
