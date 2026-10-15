import CoreGraphics
import Foundation

/// The conversion: a file rides the belt into a press, which squashes it flat
/// when the target is lossy and puts the same file in a new box when it is
/// lossless (html:451-528).
///
/// Belt, press and file all run from the clock, one file every 2.4 s: a
/// batch reports whole files only, and its count is the readout's job, not
/// the picture's (spec §3.2). `progress.lossless` (the running preset) picks
/// squash or re-box, and the file wears `labels.source` before the press and
/// `labels.target` after it, printing nothing for a word it does not have.
/// Finished, the press parks up, the belt stops and OK blinks under the head.
enum ConvertScene {
    /// Seconds one file takes from the left end of the belt to the right.
    static let period: TimeInterval = 2.4
    /// The belt's top edge; files stand on it.
    static let base: CGFloat = 82
    /// A file's height before the press, and a lossy one's after it.
    static let fatHeight: CGFloat = 40
    static let flatHeight: CGFloat = 14
    /// Where the press plate rests (its underside), parked or between files.
    static let plateRest: CGFloat = 24

    /// u ≈ 0.55 of the first file: under the press, a lossy file squashed
    /// flat and squinting, a lossless one already in its new box.
    static let keyTime: TimeInterval = 1.32

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let base = Self.base, lossy = !input.progress.lossless
        let run = !input.isFinished
        let local = input.time
        let u = run ? local.truncatingRemainder(dividingBy: period) / period : 0
        let item = Int((local / period).rounded(.down))
        let lerp = BusyNoise.lerp

        // The belt, its treads stepping 2.5 units a frame, and its rollers.
        d.line(6, base + 1, 234, base + 1)
        let off = run ? CGFloat((input.step * 5) % 20) / 2 : 0
        var tread = 6 + off
        while tread < 234 {
            d.line(tread, base + 3, tread, base + 6, .dim)
            tread += 10
        }
        d.circle(8, base + 4, 3, .dim)
        d.circle(232, base + 4, 3, .dim)

        // The press head.
        d.rect(96, 4, 48, 9, .foreground, fill: .background)
        d.line(100, 8.5, 140, 8.5, .dim)

        // The plate comes down to the file's new height, holds, and goes back.
        var plate = plateRest
        let squashTo = lossy ? base - flatHeight : base - fatHeight
        if run {
            if u >= 0.35 && u < 0.5 {
                plate = lerp(plateRest, squashTo, CGFloat((u - 0.35) / 0.15))
            } else if u >= 0.5 && u < 0.62 {
                plate = squashTo
            } else if u >= 0.62 && u < 0.75 {
                plate = lerp(squashTo, plateRest, CGFloat((u - 0.62) / 0.13))
            }
        }

        // The spring between head and plate.
        let coils = 7
        let top: CGFloat = 13, bottom = plate - 4
        var spring = [CGPoint(x: 120, y: top)]
        for i in 1..<coils {
            spring.append(CGPoint(x: i % 2 == 1 ? 113 : 127, y: lerp(top, bottom, CGFloat(i) / CGFloat(coils))))
        }
        spring.append(CGPoint(x: 120, y: bottom))
        d.poly(spring, .dim)
        d.rect(100, plate - 4, 40, 4, .foreground, fill: .background)

        if input.isFinished && input.markLit {
            d.text("OK", 120, 36, .hot, size: 8, align: .center)
        }
        guard run else { return d }

        // The file: in from the left, under the press, out to the right.
        let x: CGFloat, h: CGFloat
        if u < 0.35 {
            x = lerp(14, 120, CGFloat(u / 0.35))
            h = fatHeight
        } else if u < 0.75 {
            x = 120
            h = u < 0.5 ? min(fatHeight, base - plate) : (lossy ? flatHeight : fatHeight)
        } else {
            x = lerp(120, 214, CGFloat((u - 0.75) / 0.25))
            h = lossy ? flatHeight : fatHeight
        }
        let post = u >= 0.5
        let w = 24 + (fatHeight - h) * 0.3, y = base - h
        if !lossy && post {
            d.rect(x - w / 2 - 3, y - 3, w + 6, h + 3, .cool)
        }
        d.rect(x - w / 2, y, w, h, .foreground, fill: .background)

        // Its waveform: five bars, a different file every pass.
        for i in 0..<5 {
            let bx = x - w / 2 + CGFloat(i + 1) * w / 6
            let bh = CGFloat(0.3 + 0.7 * BusyNoise.unit(Double(item * 9 + i))) * (h - 12) * 0.5
            let my = y + 8 + (h - 8) / 2
            d.line(bx, my - bh, bx, my + bh, .cool)
        }

        // Its eyes, squinting while a lossy press bears down.
        let squint = lossy && u >= 0.42 && u < 0.62
        let ey = y + 4.5
        if squint {
            d.poly([CGPoint(x: x - 6, y: ey - 1.5), CGPoint(x: x - 4, y: ey), CGPoint(x: x - 6, y: ey + 1.5)])
            d.poly([CGPoint(x: x + 6, y: ey - 1.5), CGPoint(x: x + 4, y: ey), CGPoint(x: x + 6, y: ey + 1.5)])
        } else {
            d.dot(x - 4, ey, 0.9)
            d.dot(x + 4, ey, 0.9)
        }

        // Lossy: what is squeezed out puffs off both sides.
        if lossy && u >= 0.48 && u < 0.6 {
            for sign: CGFloat in [-1, 1] {
                let ex = x + sign * (w / 2 + 3)
                d.line(ex, base - 4, ex + sign * 6, base - 4, .dim)
                d.line(ex, base - 9, ex + sign * 4, base - 10, .dim)
            }
        }
        // Lossless: the press flashes as it boxes the file.
        if !lossy && u >= 0.5 && u < 0.62 {
            d.line(97, plate - 2, 92, plate - 5, .hot)
            d.line(143, plate - 2, 148, plate - 5, .hot)
        }

        // The format it is, then the format it became; nothing for a word
        // the job did not know.
        if let label = post ? input.labels.target : input.labels.source {
            let size: CGFloat = 6
            d.text(label, onGlass(label, centredAt: x, size: size),
                   y - (post && !lossy ? 6 : 3), post ? .hot : .dim, size: size, align: .center)
        }
        return d
    }

    /// The source format standing tall, the dashes, and the result: a flat
    /// block when lossy, the same tall file in a cool box when lossless
    /// (html:470, `MINI.tall` and `MINI.flat`, html:292-296). Both are
    /// centred on the dashed line, y = 6.
    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)

        let source: CGFloat = 3
        d.rect(source, 1.2, 5.5, 9.6)
        d.line(source + 2, 3.5, source + 2, 8.5, .cool)
        d.line(source + 3.6, 4.5, source + 3.6, 7.5, .cool)

        BusyGlyphs.miniTrack(&d, input)

        let x: CGFloat = 87, end = BusyGlyphs.miniEndInk(input)
        if input.progress.lossless {
            d.rect(x - 0.6, 0.6, 8.6, 10.8, .cool)
            d.rect(x + 1.4, 2.4, 4.6, 7.2, end)
        } else {
            d.rect(x - 1, 3.8, 9.5, 4.4, end)
            d.line(x + 1.5, 6, x + 6, 6, .cool)
        }
        return d
    }

    /// A centred label's x, nudged in just far enough that a long word
    /// (`BusyLabels` allows 12 characters) at either end of the belt stays on
    /// the glass. The formats this prints (FLAC, MP3, ALAC…) never move.
    private static func onGlass(_ label: String, centredAt x: CGFloat, size: CGFloat) -> CGFloat {
        let half = CGFloat(label.count) * size * BusyDrawing.textAdvance / 2
        return min(max(x, half), BusyDrawing.sceneSize.width - half)
    }
}
