import CrateDiggerCore
import SwiftUI

/// The missing-artwork placeholder: an empty case for the album's media —
/// a CD jewel case with no insert behind the plastic, or a bare vinyl inner
/// sleeve with ring wear and no record in it. "You own the case, the artwork
/// is missing" reads truer than an abstract generated poster.
struct EmptyMediaCase: View {
    let format: MediaFormat?
    var seed: String = ""

    var body: some View {
        if format == .vinyl {
            EmptyVinylSleeve(seed: seed)
                .aspectRatio(1, contentMode: .fit)
        } else {
            // The clear lid is square — that's the 1×1 slot a cover would
            // fill — and the hinge spine adds width outside that square,
            // like the real thing.
            EmptyJewelCase()
                .aspectRatio(1 + EmptyJewelCase.spineFraction, contentMode: .fit)
        }
    }
}

/// An empty CD jewel case seen from the front: ribbed hinge spine on the left,
/// clear tray with hinge pins, closure clips on the right edge, plastic gloss.
private struct EmptyJewelCase: View {
    /// Extra width the hinge spine adds to the left of the square lid.
    static let spineFraction: CGFloat = 0.13

    @Environment(\.carbon) private var theme

    var body: some View {
        let isDark = theme.isDark
        ZStack {
            // Tray plastic behind the clear lid.
            LinearGradient(
                colors: isDark
                    ? [Color(white: 0.24), Color(white: 0.13)]
                    : [Color(white: 0.94), Color(white: 0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Diagonal gloss streak across the lid.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: .white.opacity(isDark ? 0.06 : 0.35), location: 0.46),
                    .init(color: .clear, location: 0.62)
                ],
                startPoint: UnitPoint(x: 0.1, y: 0),
                endPoint: UnitPoint(x: 0.9, y: 1)
            )

            Canvas { context, size in
                let w = size.width
                let h = size.height
                // The square lid occupies the right h×h; the spine gets the
                // extra width the aspect ratio reserved on the left.
                let spineW = max(w - h, 0)
                let lid = w - spineW

                // Hinge spine: dark strip with vertical ridges.
                context.fill(Path(CGRect(x: 0, y: 0, width: spineW, height: h)),
                             with: .color(.black.opacity(isDark ? 0.72 : 0.78)))
                let ridgeCount = 6
                for i in 1...ridgeCount {
                    let x = spineW * CGFloat(i) / CGFloat(ridgeCount + 1)
                    context.fill(Path(CGRect(x: x, y: h * 0.02, width: max(w / 300, 0.7), height: h * 0.96)),
                                 with: .color(.white.opacity(0.10)))
                }

                // Hinge pins in the tray corners.
                let pinR = w * 0.028
                let pinColor = GraphicsContext.Shading.color(isDark ? .white.opacity(0.14) : .black.opacity(0.14))
                let pinRim = GraphicsContext.Shading.color(isDark ? .black.opacity(0.5) : .black.opacity(0.22))
                for (px, py) in [(spineW + lid * 0.075, h * 0.075), (spineW + lid * 0.925, h * 0.075),
                                 (spineW + lid * 0.075, h * 0.925), (spineW + lid * 0.925, h * 0.925)] {
                    let rect = CGRect(x: px - pinR, y: py - pinR, width: pinR * 2, height: pinR * 2)
                    context.fill(Path(ellipseIn: rect), with: pinColor)
                    context.stroke(Path(ellipseIn: rect), with: pinRim, lineWidth: max(w / 400, 0.5))
                }

                // Closure clip slots on the right edge.
                let slotW = max(w / 220, 1)
                for sy in [h * 0.30, h * 0.62] {
                    context.fill(Path(CGRect(x: w * 0.985 - slotW, y: sy, width: slotW, height: h * 0.08)),
                                 with: .color(.black.opacity(isDark ? 0.6 : 0.3)))
                }

                // Lid edge highlight along the top.
                context.fill(Path(CGRect(x: spineW, y: 0, width: w - spineW, height: max(h / 300, 0.7))),
                             with: .color(.white.opacity(isDark ? 0.12 : 0.7)))
            }
        }
        .drawingGroup(opaque: true)
    }
}

/// An empty vinyl inner sleeve: plain paper with the ghost ring a record
/// pressed into it, and a center hole opening onto shadow — no record inside.
private struct EmptyVinylSleeve: View {
    @Environment(\.carbon) private var theme
    let seed: String

    var body: some View {
        let isDark = theme.isDark
        ZStack {
            // Paper: warm off-white, or muted dark stock in dark mode.
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.22, green: 0.21, blue: 0.19), Color(red: 0.15, green: 0.145, blue: 0.13)]
                    : [Color(red: 0.93, green: 0.90, blue: 0.84), Color(red: 0.84, green: 0.81, blue: 0.74)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                let w = size.width
                let h = size.height
                let center = CGPoint(x: w / 2, y: h / 2)

                // Ring wear: the ghost impression of the record that used to live here.
                let wearR = w * 0.42
                let wearRect = CGRect(x: center.x - wearR, y: center.y - wearR, width: wearR * 2, height: wearR * 2)
                context.stroke(Path(ellipseIn: wearRect),
                               with: .color(.black.opacity(isDark ? 0.22 : 0.09)),
                               lineWidth: w * 0.012)
                context.stroke(Path(ellipseIn: wearRect.insetBy(dx: w * 0.015, dy: w * 0.015)),
                               with: .color(.white.opacity(isDark ? 0.05 : 0.35)),
                               lineWidth: w * 0.006)

                // Center hole opening onto the sleeve's shadowed inside.
                let holeR = w * 0.16
                let holeRect = CGRect(x: center.x - holeR, y: center.y - holeR, width: holeR * 2, height: holeR * 2)
                context.fill(Path(ellipseIn: holeRect), with: .color(.black.opacity(isDark ? 0.72 : 0.5)))
                // Paper thickness catching light on the hole's lower rim.
                var rim = Path()
                rim.addArc(center: center, radius: holeR, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                context.stroke(rim, with: .color(.white.opacity(isDark ? 0.12 : 0.55)), lineWidth: max(w / 250, 0.8))

                // Open top edge of the sleeve.
                context.fill(Path(CGRect(x: 0, y: h * 0.015, width: w, height: max(h / 280, 0.7))),
                             with: .color(.black.opacity(isDark ? 0.35 : 0.12)))

                // Paper grain.
                var rng = SeededRandom(seed: Self.hashSeed(seed))
                for _ in 0..<500 {
                    let x = rng.nextDouble() * w
                    let y = rng.nextDouble() * h
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                                 with: .color(.black.opacity(rng.nextDouble() * (isDark ? 0.25 : 0.12))))
                }
            }
        }
        .drawingGroup(opaque: true)
    }

    private static func hashSeed(_ seed: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for ch in seed.unicodeScalars {
            hash ^= UInt64(ch.value)
            hash &*= 1099511628211
        }
        return hash
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }

    mutating func nextDouble() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}
