import CoreGraphics
import Foundation

/// The stream download (html:659-727): a radio mast sends out rings, data
/// hops along the line into a cassette, and through its window the take-up
/// pack grows as the supply pack shrinks. The tape is the percentage.
///
/// What drives what (spec §3.2):
/// - **Clock** (`input.time`): the mast's rings, the data blocks and the hub
///   spin, so the picture moves at 8 fps however slowly yt-dlp reports.
/// - **Fraction** (`progress.fraction`, 0 while unknown): the two packs.
/// - **Label:** the stream's channel (`labels.source`), or "STREAM".
/// - **Finished:** the hubs stop, the data and rings go dark, and the label
///   reads DONE in steady hot. The approved cassette has **no blinking
///   element** (html:702 draws DONE without `blink`), so `markLit` does not
///   change the picture; the mini's cassette blinks instead.
enum DownloadScene {
    // MARK: - Geometry (scene units, from the sketch)

    /// The mast's tip, where the rings are centred.
    static let mast = CGPoint(x: 22, y: 28)
    /// The cassette shell: 100.4 × 63.8 mm, so about 1.57 : 1.
    static let cassette = CGRect(x: 116, y: 16, width: 104, height: 66)
    /// The window: a stadium (radius = half its height) with a hub centred in
    /// each round end.
    static let window = CGRect(x: 137, y: 36, width: 62, height: 18)
    /// The data line runs level with the hubs, from the mast to the cassette.
    static let dataStart: CGFloat = 38, dataSpan: CGFloat = 74

    // MARK: - Picture

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let run = !input.isFinished
        // The sketch's done state is p = 1 (cycleState clamps local / run),
        // so a finished download shows a full take-up even if its last
        // report never reached 100 %.
        let p = CGFloat(input.isFinished ? 1 : input.progress.fraction ?? 0)

        // The mast: a pole on an A-frame with a cross brace, a hot tip, and
        // three ring pairs lit in turn every quarter second.
        let mx = mast.x, my = mast.y
        d.line(mx, my + 2, mx, 70)
        d.line(mx, 70, mx - 8, 90); d.line(mx, 70, mx + 8, 90); d.line(mx - 5, 81, mx + 5, 81)
        d.dot(mx, my, 2, .hot)
        let lit = run ? Int((input.time / 0.25).rounded(.down)) % 4 : 0
        for (j, r) in [CGFloat(6), 11, 16].enumerated() {
            let ink: BusyInk = j < lit ? .cool : .dim
            d.arc(mx, my, r, -0.8, 0.8, ink)
            d.arc(mx, my, r, .pi - 0.8, .pi + 0.8, ink)
        }

        // Data along the line, level with the hubs: seven blocks 11 apart,
        // stepping 2 units per frame and wrapping inside the line.
        d.line(dataStart, 45, dataStart + dataSpan, 45, .dim)
        if run {
            let shift = input.step * 2
            for i in 0..<7 {
                let x = dataStart + CGFloat((i * 11 + shift) % Int(dataSpan))
                d.block(x - 1.2, 43.8, 2.4, 2.4, .cool)
            }
        }

        // The cassette shell, background-filled so nothing behind it shows,
        // and its four corner screws.
        let x0 = cassette.minX, y0 = cassette.minY, cw = cassette.width, ch = cassette.height
        d.roundedRect(x0, y0, cw, ch, 4, .foreground, fill: .background)
        for (sx, sy) in [(x0 + 5, y0 + 5), (x0 + cw - 5, y0 + 5), (x0 + 5, y0 + ch - 5), (x0 + cw - 5, y0 + ch - 5)] {
            d.circle(sx, sy, 1.4, .dim)
        }

        // The label, with its side letter.
        d.roundedRect(x0 + 8, y0 + 6, cw - 16, 38, 3, .dim)
        d.line(x0 + 12, y0 + 15, x0 + cw - 12, y0 + 15, .dim)
        if input.isFinished {
            d.text("DONE", x0 + 22, y0 + 13, .hot, size: 5.5)
        } else {
            d.text(input.labels.source ?? "STREAM", x0 + 22, y0 + 13, .dim, size: 5.5)
        }
        d.text("A", x0 + 12, y0 + 35, .foreground, size: 9)

        // The window. The packs are circles larger than the window is tall,
        // cut to the stadium as the sketch's ctx.clip() cuts them.
        let wx = window.minX, wy = window.minY, ww = window.width, wh = window.height
        let left = CGPoint(x: wx + 9, y: wy + 9), right = CGPoint(x: wx + ww - 9, y: wy + 9)
        d.clipped(to: window, radius: 9) { d in
            d.circle(left.x, left.y, 6 + 9 * (1 - p), .dim)
            d.circle(right.x, right.y, 6 + 9 * p, .cool)
        }
        d.roundedRect(wx, wy, ww, wh, 9, .foreground)
        // Hubs: six spokes each, turning 30° a frame while running.
        let spin = run ? Double(input.step) * (.pi / 6) : 0
        for hub in [left, right] {
            d.circle(hub.x, hub.y, 4.4, .foreground, fill: .background)
            for j in 0..<6 {
                let a = spin + Double(j) * .pi / 3
                let p1 = BusyNoise.polar(hub.x, hub.y, 2.6, a), p2 = BusyNoise.polar(hub.x, hub.y, 4.4, a)
                d.line(p1.x, p1.y, p2.x, p2.y)
            }
        }

        // The head area along the bottom edge: the trapezoid, two guide
        // holes and the two small capstan windows.
        d.poly([CGPoint(x: x0 + 18, y: y0 + ch), CGPoint(x: x0 + 24, y: y0 + 52),
                CGPoint(x: x0 + cw - 24, y: y0 + 52), CGPoint(x: x0 + cw - 18, y: y0 + ch)])
        d.circle(x0 + 32, y0 + 59, 2, .dim); d.circle(x0 + cw - 32, y0 + 59, 2, .dim)
        d.rect(x0 + cw / 2 - 6, y0 + 56, 3, 3, .dim); d.rect(x0 + cw / 2 + 3, y0 + 56, 3, 3, .dim)
        return d
    }

    // MARK: - Mini (html:675)

    /// Antenna - - - - cassette. The cassette is the destination, so it
    /// takes `miniEndInk` and blinks hot once the download has finished.
    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        miniAntenna(&d, cx: 6, input)
        BusyGlyphs.miniTrack(&d, input)
        miniCassette(&d, x: 84.4, input, BusyGlyphs.miniEndInk(input))
        return d
    }

    /// `MINI.antenna` (html:308-312): a mast on two legs with a hot tip,
    /// sending a ring pair out on every other step while running.
    static func miniAntenna(_ d: inout BusyDrawing, cx: CGFloat, _ input: BusySceneInput) {
        d.line(cx, 3.2, cx, 10.6); d.line(cx, 7.6, cx - 2.6, 11); d.line(cx, 7.6, cx + 2.6, 11)
        d.dot(cx, 2.2, 1, .hot)
        if !input.isFinished && input.step % 2 == 0 {
            d.arc(cx, 2.2, 3.2, -0.7, 0.7, .cool)
            d.arc(cx, 2.2, 3.2, .pi - 0.7, .pi + 0.7, .cool)
        }
    }

    /// `MINI.cassette` (html:313-322): the shell in `ink`, two hubs whose
    /// cool bar turns 60° a step while running, and the head-area trapezoid.
    static func miniCassette(_ d: inout BusyDrawing, x: CGFloat, _ input: BusySceneInput, _ ink: BusyInk) {
        d.roundedRect(x, 1.6, 11.2, 8.6, 1.4, ink)
        let a = Double(input.isFinished ? 0 : input.step) * .pi / 3
        for cx in [x + 3.3, x + 7.9] {
            d.circle(cx, 5.4, 1.6)
            let p1 = BusyNoise.polar(cx, 5.4, 1.6, a), p2 = BusyNoise.polar(cx, 5.4, 1.6, a + .pi)
            d.line(p1.x, p1.y, p2.x, p2.y, .cool)
        }
        d.poly([CGPoint(x: x + 2.4, y: 10.2), CGPoint(x: x + 3.4, y: 8.6),
                CGPoint(x: x + 7.8, y: 8.6), CGPoint(x: x + 8.8, y: 10.2)], ink)
    }

    /// The still (Reduce Motion) frame: half a second in, two of the mast's
    /// three ring pairs are lit, so the still reads as "transmitting" rather
    /// than a dark mast.
    static let keyTime: TimeInterval = 0.5
}
