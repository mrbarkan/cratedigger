import CoreGraphics
import Foundation

/// The scan (html:530-657): you stand over a crate and flip through it.
/// Records tip toward you one at a time; a find lifts out orange and lands on
/// the picked pile; a spent crate slides away and the next one, with its own
/// divider, slides in.
///
/// Ported from the sketch's `draw` line for line, with one structural change:
/// the sketch runs four crates and stops, the port **cycles** them forever
/// (A–F, G–M, N–S, T–Z, A–F…) off the clock. A scan's total is nil for its
/// first phase and can drop when a multi-folder dig moves on, so crates tied
/// to the fraction would stall or run backwards; progress drives the mini's
/// dashes and the pane's readout instead (spec §3.2).
///
/// What the user's feedback pinned, and this file must keep:
/// - **No record bottoms.** Standing records end at `front + 4` and the
///   front wall, filled with the glass, is drawn *after* them. Do not reorder.
/// - **Crate-sized pile.** A picked record is as wide as a record in the crate.
/// - **The mini's fallen record stays inside the mini crate.**
enum ScanScene {
    // MARK: - Geometry and timing (html:550-612)

    /// Records per crate.
    static let recordCount = 12
    /// One flip is three 1/8 s frames: stands, tips, lies.
    static let flipTime: TimeInterval = 0.375
    /// A crate swap is four 1/8 s frames.
    static let swapTime: TimeInterval = 0.5
    /// 12 × 0.375 + 0.5 = 5 s a crate.
    static let crateTime: TimeInterval = Double(recordCount) * flipTime + swapTime
    static let dividers = ["A–F", "G–M", "N–S", "T–Z"]

    /// The crate's front rim (`F`) and back rim (`B`), and their half-widths.
    static let front: CGFloat = 72
    static let back: CGFloat = 32
    static let frontHalf: CGFloat = 44
    static let backHalf: CGFloat = 33
    /// Where the crate on screen stands; a swap slides crates 160 either side.
    static let crateCentre: CGFloat = 86
    static let swapDistance: CGFloat = 160
    /// A record is 0.9 of the crate's width where it stands.
    static let recordWidth: CGFloat = 0.9

    /// The picked pile: centre, bottom, how deep a lying record reads, how
    /// much its far edge narrows, the gap between records, and how many show.
    static let pileX: CGFloat = 192
    static let pileBottom: CGFloat = 94
    static let pileDepth: CGFloat = 30
    static let pileNarrow: CGFloat = 0.82
    static let pileGap: CGFloat = 2.6
    static let pileShown = 8

    /// Four flipped and the front record standing with its cover (step 12,
    /// phase 0): the one frame that says "flipping through a crate".
    static let keyTime: TimeInterval = 1.5

    // MARK: - The clock

    /// Where the clock puts the crate: which lap of crates, which record is
    /// in front, which of its three frames, or how far a swap has slid.
    struct Moment: Equatable {
        /// The crate on screen (the outgoing one during a swap).
        var crate: Int
        /// The record being looked at; `recordCount` when the crate is spent.
        var front: Int
        /// 0 stands, 1 tips toward you, 2 lies on the wall (the next stands).
        var phase: Int
        /// The swap's slide, 0, 0.25, 0.5 or 0.75; nil while flipping.
        var swap: CGFloat?
    }

    /// The sketch's `c`, `f`, `phase` and swap `u` (html:554-559, 631), from
    /// whole 8 fps steps rather than float division, so a step boundary
    /// never lands a frame early: 40 steps a crate, 36 of flipping in threes,
    /// then four of swap.
    static func moment(_ time: TimeInterval) -> Moment {
        let framesPerFlip = 3
        let flipSteps = recordCount * framesPerFlip
        let crateSteps = BusySignalTiming.step(crateTime)
        let step = BusySignalTiming.step(time)
        let crate = step / crateSteps, local = step % crateSteps
        if local < flipSteps {
            return Moment(crate: crate, front: local / framesPerFlip, phase: local % framesPerFlip, swap: nil)
        }
        let swapSteps = crateSteps - flipSteps
        return Moment(crate: crate, front: recordCount, phase: 0,
                      swap: CGFloat(local - flipSteps) / CGFloat(swapSteps))
    }

    /// A record's id: every lap of crates turns up different records.
    static func record(_ crate: Int, _ i: Int) -> Int { crate * recordCount + i }

    /// The sketch's `find` (html:562): about one record in six is a keeper.
    /// Doubles, so a long dig's ids can never overflow `id × 7`.
    static func isFind(_ id: Int) -> Bool {
        BusyNoise.unit(Double(id) * 7 + 1) < 0.16
    }

    // MARK: - Picture

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let now = moment(input.time)

        // The crate the finish holds (spec §3.2): the one on screen, or the
        // incoming one when the finish lands inside a swap. Spent, so every
        // record leans on the wall, standing still.
        let held = now.swap == nil ? now.crate : now.crate + 1
        let crateShown = input.isFinished ? held : now.crate
        let looking = input.isFinished ? recordCount : now.front
        let phase = input.isFinished ? 0 : now.phase

        // A swap slides the crates up to 160 units off the glass; the sketch
        // relied on its canvas edge, the port says so.
        d.clipped(to: CGRect(origin: .zero, size: BusyDrawing.sceneSize), radius: 0) { d in
            if let u = now.swap, !input.isFinished {
                crate(&d, cx: crateCentre - u * swapDistance, crate: now.crate, front: recordCount, phase: 0)
                crate(&d, cx: crateCentre + (1 - u) * swapDistance, crate: now.crate + 1, front: 0, phase: 0)
            } else {
                crate(&d, cx: crateCentre, crate: crateShown, front: phase == 2 ? looking + 1 : looking, phase: phase)
            }
        }

        pile(&d, flipped: record(crateShown, looking) + (phase == 2 ? 1 : 0))

        if input.isFinished && input.markLit {
            d.text("DONE", crateCentre, 12, .hot, size: 7, align: .center)
        }
        return d
    }

    /// One crate seen from above and in front (html:603-628): the opening
    /// narrows toward the back, records stand in rows, the flipped ones lean
    /// on the front wall. `front` is the record being looked at;
    /// `recordCount` means none is left.
    private static func crate(_ d: inout BusyDrawing, cx: CGFloat, crate: Int, front k: Int, phase: Int) {
        let n = recordCount, F = front, B = back, hf = frontHalf, hb = backHalf
        func rimY(_ depth: CGFloat) -> CGFloat { BusyNoise.lerp(F, B, depth) }
        func halfAt(_ depth: CGFloat) -> CGFloat { BusyNoise.lerp(hf, hb, depth) }
        func stick(_ depth: CGFloat) -> CGFloat { BusyNoise.lerp(22, 15, depth) }
        func depth(_ i: Int) -> CGFloat { (CGFloat(i) + 0.5) / CGFloat(n) * 0.92 }

        d.line(cx - hb, B, cx + hb, B, .dim)
        d.line(cx - hf, F, cx - hb, B)
        d.line(cx + hf, F, cx + hb, B)

        // The records still standing, back to front. Each ends at F + 4,
        // which the wall drawn below covers: that is the high camera.
        for i in stride(from: n - 1, to: k, by: -1) {
            let dep = depth(i), w = halfAt(dep) * recordWidth, top = rimY(dep) - stick(dep)
            d.rect(cx - w, top, w * 2, F + 4 - top, .dim, fill: .background)
        }

        if k < n {
            let dep = depth(k), w = halfAt(dep) * recordWidth, top = rimY(dep) - stick(dep)
            let bottom = F + 4, id = record(crate, k), hot = isFind(id)
            if phase == 1 && hot {
                // A find lifts out, orange.
                face(&d, cx: cx, w: w, top: top - 12, bottom: bottom, id: id, art: .hot, frame: .hot)
                sparkle(&d, cx: cx, w: w, top: top - 12)
            } else if phase == 1 {
                // Tipping toward you: its top edge comes forward and widens.
                let t2 = BusyNoise.lerp(top, F - 6, 0.55), w2 = w * 1.08
                d.poly([CGPoint(x: cx - w2, y: t2), CGPoint(x: cx + w2, y: t2),
                        CGPoint(x: cx + w, y: bottom), CGPoint(x: cx - w, y: bottom)],
                       .foreground, closed: true, fill: .background)
                d.line(cx - w2 + 5, t2 + 4, cx - w2 + 14, t2 + 4, .cool)
            } else {
                face(&d, cx: cx, w: w, top: top, bottom: bottom, id: id,
                     art: hot ? .hot : .cool, frame: hot ? .hot : .foreground)
                if hot { sparkle(&d, cx: cx, w: w, top: top) }
            }
        }

        // The front wall, with its divider and handle. After the records.
        d.rect(cx - hf, F, hf * 2, 20, .foreground, fill: .background)
        d.roundedRect(cx - 12, F + 11, 24, 5, 2.5, .foreground)
        d.text(dividers[((crate % dividers.count) + dividers.count) % dividers.count],
               cx - hf + 4, F + 8, .dim, size: 5.5)

        // The flipped records that were not keepers, leaning forward over
        // the wall's top edge (drawn after it: the approved look).
        let leaning = (0..<min(k, n)).filter { !isFind(record(crate, $0)) }.count
        if leaning > 0 {
            let shown = min(leaning, 5)
            let bottom = F + 1.5 + CGFloat(shown) * 1.3
            d.poly([CGPoint(x: cx - hf + 2, y: F - 3), CGPoint(x: cx + hf - 2, y: F - 3),
                    CGPoint(x: cx + hf + 3, y: bottom), CGPoint(x: cx - hf - 3, y: bottom)],
                   .foreground, closed: true, fill: .background)
            for j in 1..<shown {
                let y = BusyNoise.lerp(F - 3, bottom, CGFloat(j) / CGFloat(shown))
                d.line(cx - hf + 1, y, cx + hf + 1, y, .dim)
            }
        }
    }

    /// The picked pile (html:636-648): every find so far lying flat, each as
    /// wide as a record in the crate, at most eight; the top one shows the
    /// cover of the last find.
    ///
    /// Counted backwards from the newest record and stopped at the eighth
    /// find, which is all the pile can show: the sketch counts from id 0
    /// every frame, which in a cyclic dig grows with the dig's length.
    private static func pile(_ d: inout BusyDrawing, flipped: Int) {
        var picked = 0, last: Int?
        var id = flipped - 1
        while id >= 0 && picked < pileShown {
            if isFind(id) {
                picked += 1
                if last == nil { last = id }
            }
            id -= 1
        }

        let px = pileX, rw = frontHalf * recordWidth, depthH = pileDepth, narrow = pileNarrow
        for j in 0..<picked {
            let y = pileBottom - CGFloat(j) * pileGap
            d.poly([CGPoint(x: px - rw, y: y), CGPoint(x: px + rw, y: y),
                    CGPoint(x: px + rw * narrow, y: y - depthH), CGPoint(x: px - rw * narrow, y: y - depthH)],
                   .foreground, closed: true, fill: .background)
        }
        guard picked > 0, let last else { return }
        let top = pileBottom - CGFloat(picked - 1) * pileGap - depthH
        for line in art(last) {
            d.poly(line.map { p in
                let k = BusyNoise.lerp(narrow, 1, p.y / 32)
                return CGPoint(x: px + p.x * rw / 30 * 1.1 * k, y: top + p.y * depthH / 32)
            }, .cool)
        }
    }

    /// A record's face (html:586-590): the sleeve, filled with the glass,
    /// and its cover art scaled into it.
    private static func face(_ d: inout BusyDrawing, cx: CGFloat, w: CGFloat, top: CGFloat, bottom: CGFloat,
                             id: Int, art artInk: BusyInk, frame: BusyInk) {
        d.rect(cx - w, top, w * 2, bottom - top, frame, fill: .background)
        let ku = w / 30 * 1.1, kv = min(bottom - top - 6, 34) / 32
        for line in art(id) {
            d.poly(line.map { CGPoint(x: cx + $0.x * ku, y: top + $0.y * kv) }, artInk)
        }
    }

    /// The three hot strokes over a find (html:591-595).
    private static func sparkle(_ d: inout BusyDrawing, cx: CGFloat, w: CGFloat, top: CGFloat) {
        d.line(cx - w - 2, top - 1, cx - w - 7, top - 5, .hot)
        d.line(cx + w + 2, top - 1, cx + w + 7, top - 5, .hot)
        d.line(cx, top - 3, cx, top - 8, .hot)
    }

    /// Cover art as polylines in a ±30 × 0…32 cover space (html:567-584):
    /// a title rule plus one of eight motifs, chosen by the record's id.
    static func art(_ id: Int) -> [[CGPoint]] {
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: u, y: v) }
        var lines: [[CGPoint]] = [[p(-21, 5), p(-12, 5)]]
        switch ((id % 8) + 8) % 8 {
        case 0:
            lines += [BusyNoise.ring(0, 18, 10), BusyNoise.ring(0, 18, 1.6, segments: 8)]
        case 1:
            for v: CGFloat in [10, 16, 22] { lines.append([p(-14, v), p(14, v)]) }
        case 2:
            lines.append([p(-11, 27), p(0, 8), p(11, 27), p(-11, 27)])
        case 3:
            for u: CGFloat in [-8, 0, 8] {
                for v: CGFloat in [10, 18, 26] { lines.append(BusyNoise.ring(u, v, 1.1, segments: 6)) }
            }
        case 4:
            lines.append([p(-11, 7), p(11, 7), p(11, 29), p(-11, 29), p(-11, 7)])
            lines.append([p(-5, 13), p(5, 13), p(5, 23), p(-5, 23), p(-5, 13)])
        case 5:
            lines.append((0..<15).map { i in p(-14 + CGFloat(i) * 2, 18 + 6 * CGFloat(sin(Double(i) * 0.75))) })
        case 6:
            lines.append(BusyNoise.ring(0, 24, 10, segments: 16).filter { $0.y <= 24.01 })
            lines.append([p(-16, 24), p(16, 24)])
            lines.append([p(-11, 28), p(11, 28)])
        default:
            lines.append([p(-10, 8), p(10, 28)])
            lines.append([p(10, 8), p(-10, 28)])
            lines.append(BusyNoise.ring(0, 18, 4, segments: 12))
        }
        return lines
    }

    // MARK: - Mini (html:547, 297-307)

    /// Folder → crate. The mini crate plays the big scene in three frames:
    /// the front record stands, tips toward you, then lies over the crate's
    /// front with the next one behind it. It lies *inside* the crate's width.
    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        miniFolder(&d, x: 1)
        BusyGlyphs.miniTrack(&d, input)
        miniCrate(&d, x: 85, input, BusyGlyphs.miniEndInk(input))
        return d
    }

    private static func miniFolder(_ d: inout BusyDrawing, x: CGFloat) {
        d.poly([CGPoint(x: x, y: 3), CGPoint(x: x + 3.5, y: 3), CGPoint(x: x + 4.6, y: 4.3),
                CGPoint(x: x + 10, y: 4.3), CGPoint(x: x + 10, y: 10.6), CGPoint(x: x, y: 10.6)],
               .foreground, closed: true)
    }

    private static func miniCrate(_ d: inout BusyDrawing, x: CGFloat, _ input: BusySceneInput, _ ink: BusyInk) {
        let phase = input.isFinished ? 0 : input.step % 3
        d.line(x + 2, 1.2, x + 8.4, 1.2, .dim)
        if phase == 0 { d.rect(x + 1.2, 2.6, 8, 5, .cool, fill: .background) }
        if phase == 1 { d.rect(x + 0.8, 4.6, 8.8, 3, .cool, fill: .background) }
        d.rect(x, 6.6, 10.4, 4.4, ink, fill: .background)
        if phase == 2 { d.line(x + 1, 7.6, x + 9.4, 7.6, .cool) }
    }
}
