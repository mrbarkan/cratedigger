import CoreGraphics
import Foundation

/// The CD rip (html:337-391): a disc turning in stepped jumps throws notes
/// across the gap into the file being written, which fills line by line;
/// each finished track drops onto a stack of slabs. When the rip is done the
/// disc stops, the file reads OK and a check blinks over the stack.
///
/// Ported line for line from the sketch's `draw` and `mini`, with its cycling
/// demo state swapped for `BusySceneInput` (spec §3.2):
/// - the disc and the notes run on the clock (`time`, frozen at the finish);
/// - the file fills with `unitFraction`, the ledger's estimate inside the
///   current track, since a serial rip only reports whole tracks;
/// - the stack and the falling slab follow `completed`, scaled onto at most
///   five slabs.
enum RipScene {
    // MARK: - Geometry (scene units, as html:362-389)

    /// The disc's centre and rim.
    static let discCentre = CGPoint(x: 50, y: 50)
    static let discRadius: CGFloat = 36
    /// Radians of turn per second of clock: at 8 fps that is ~34° a step,
    /// which reads as the stepped spin the sketch was approved with.
    static let spinRate: Double = 4.7

    /// A note leaves the disc every `noteEvery` seconds and takes `noteLife`
    /// to reach the file.
    static let noteEvery: Double = 0.6
    static let noteLife: Double = 2.0

    /// The file being written: a dog-eared page.
    static let fileX: CGFloat = 165, fileY: CGFloat = 30
    static let fileWidth: CGFloat = 22, fileHeight: CGFloat = 30, fileEar: CGFloat = 6

    /// The stack. Slab `j` (0 at the bottom) sits at `slabY(j)`.
    static let slabX: CGFloat = 198
    static let slabWidth: CGFloat = 28, slabHeight: CGFloat = 3
    /// At most this many slabs, the sketch's own maximum (html:344). A sixth
    /// at slabY(5) = 60 (y 60-63) would hold the check's vertex (210, 61).
    static let maxSlabs = 5
    /// How long a slab takes to fall from the file's foot onto the stack.
    static let fallDuration: TimeInterval = 0.5

    static func slabY(_ j: Int) -> CGFloat { 85 - CGFloat(j) * 5 }

    /// 1.25 s: three notes strung across the gap (ages 1.25, 0.65, 0.05 s)
    /// and the disc's index off the axis, so the one frame reads as ripping.
    static let keyTime: TimeInterval = 1.25

    // MARK: - Picture

    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        let local = input.time
        let total = Self.total(input.progress)
        let k = min(input.progress.completed, total)

        BusyGlyphs.disc(&d, cx: discCentre.x, cy: discCentre.y, radius: discRadius, angle: local * spinRate)

        if !input.isFinished {
            let first = Int(((local - noteLife) / noteEvery).rounded(.down))
            let last = Int((local / noteEvery).rounded(.down))
            for i in max(first, 0)...max(last, 0) {
                let age = local - Double(i) * noteEvery
                if age < 0 || age > noteLife { continue }
                let u = age / noteLife
                let x = BusyNoise.lerp(86, 170, CGFloat(u))
                let y = 47 - 16 * sin(Double.pi * u) + 2.5 * sin(age * 7 + Double(i))
                BusyGlyphs.note(&d, x: x, y: CGFloat(y), kind: i % 2, ink: .cool, scale: u > 0.85 ? 0.6 : 1)
            }
        }

        // The file, filled with the background so notes arriving behind it
        // disappear into it.
        let fx = fileX, fy = fileY, fw = fileWidth, fh = fileHeight, ear = fileEar
        d.poly([CGPoint(x: fx, y: fy), CGPoint(x: fx + fw - ear, y: fy), CGPoint(x: fx + fw, y: fy + ear),
                CGPoint(x: fx + fw, y: fy + fh), CGPoint(x: fx, y: fy + fh)],
               .foreground, closed: true, fill: .background)
        d.poly([CGPoint(x: fx + fw - ear, y: fy), CGPoint(x: fx + fw - ear, y: fy + ear),
                CGPoint(x: fx + fw, y: fy + ear)], .foreground)
        if !input.isFinished {
            // Bottom up in 2.5-unit lines; the loop always draws the bottom
            // one, so an empty file still shows a line being written.
            let top = fy + fh - 3 - CGFloat(input.unitFraction) * (fh - 9)
            var y = fy + fh - 3
            while y >= top {
                d.line(fx + 3, y, fx + fw - 3, y, .cool)
                y -= 2.5
            }
            d.text("T" + pad2(min(k + 1, total)), fx + fw / 2, fy - 4, .dim, size: 6, align: .center)
        } else {
            d.text("OK", fx + fw / 2, fy + fh / 2 + 2, .hot, size: 7, align: .center)
        }

        // The stack, on its dim shelf.
        d.line(194, 89, 232, 89, .dim)
        let shownNow = shown(k, total: total)
        let falling = k >= 1 && !input.isFinished
            && shownNow > shown(k - 1, total: total)
            && input.unitTime < fallDuration
        for j in 0..<(falling ? shownNow - 1 : shownNow) {
            d.rect(slabX, slabY(j), slabWidth, slabHeight, .foreground)
        }
        if falling {
            // Stepped at 1/8 s like everything else (html:384-387).
            let u = CGFloat((input.unitTime / 0.125).rounded(.down) * 0.125 / fallDuration)
            d.rect(BusyNoise.lerp(fx - 3, slabX, u), BusyNoise.lerp(fy + fh - 2, slabY(shownNow - 1), u),
                   slabWidth, slabHeight, .cool)
        }

        if input.isFinished && input.markLit {
            d.poly([CGPoint(x: 205, y: 56), CGPoint(x: 210, y: 61), CGPoint(x: 221, y: 48)], .hot)
        }
        return d
    }

    // MARK: - Mini (html:357)

    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        miniDisc(&d, cx: 6, input)
        BusyGlyphs.miniTrack(&d, input)
        miniFile(&d, x: 86, ink: BusyGlyphs.miniEndInk(input), fill: input.isFinished ? 1 : input.unitFraction)
        return d
    }

    /// `MINI.disc` (html:277-282): a rim, a spindle dot and a hot index that
    /// turns 30° a step while running and rests at 0 once finished.
    static func miniDisc(_ d: inout BusyDrawing, cx: CGFloat, _ input: BusySceneInput) {
        let cy = BusyGlyphs.miniCentreY
        d.circle(cx, cy, 4.6, .foreground)
        d.dot(cx, cy, 0.8, .foreground)
        let a = Double(input.isFinished ? 0 : input.step) * Double.pi / 6
        let p1 = BusyNoise.polar(cx, cy, 1.8, a), p2 = BusyNoise.polar(cx, cy, 4, a)
        d.line(p1.x, p1.y, p2.x, p2.y, .hot)
    }

    /// `MINI.file` (html:283-285): a dog-eared page whose outline takes the
    /// destination ink, with cool lines written bottom up to `fill` (one line
    /// at 0, four at 0.95).
    static func miniFile(_ d: inout BusyDrawing, x: CGFloat, ink: BusyInk, fill: Double) {
        d.poly([CGPoint(x: x, y: 1.2), CGPoint(x: x + 5, y: 1.2), CGPoint(x: x + 7.6, y: 3.8),
                CGPoint(x: x + 7.6, y: 10.8), CGPoint(x: x, y: 10.8)], ink, closed: true)
        let top = 9.2 - CGFloat(fill) * 6
        var y: CGFloat = 9.2
        while y >= top {
            d.line(x + 1.6, y, x + 6, y, .cool)
            y -= 1.8
        }
    }

    // MARK: - Counting

    /// The disc's track count, or one more than done while it is unknown, so
    /// the stack still grows a slab per track.
    static func total(_ progress: BusyProgress) -> Int {
        if let total = progress.total, total > 0 { return total }
        return max(progress.completed + 1, 1)
    }

    /// Slabs shown for `k` finished tracks: one per track up to five, else
    /// the disc scaled onto five, so a long disc still fills the stack.
    static func shown(_ k: Int, total: Int) -> Int {
        guard k > 0 else { return 0 }
        guard total > maxSlabs else { return k }
        return Int((Double(k) * Double(maxSlabs) / Double(total)).rounded(.up))
    }

    private static func pad2(_ n: Int) -> String {
        n < 10 && n >= 0 ? "0\(n)" : "\(n)"
    }
}
