import SwiftUI

struct GeneratedPoster: View {
    @Environment(\.carbon) private var theme
    let seed: String

    var body: some View {
        ZStack {
            radialBase
            angularRays
            noiseOverlay
        }
        .drawingGroup(opaque: true)
    }

    private var radialBase: some View {
        ZStack {
            theme.sunHi
                .overlay(
                    LinearGradient(
                        colors: [theme.sunHi, theme.orange, theme.ink2],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RadialGradient(
                colors: [theme.sun, .clear],
                center: UnitPoint(x: 0.30, y: 0.20),
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [theme.orange, .clear],
                center: UnitPoint(x: 0.80, y: 0.30),
                startRadius: 0,
                endRadius: 280
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [theme.orangeLo, .clear],
                center: UnitPoint(x: 0.70, y: 0.90),
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [theme.ink, .clear],
                center: UnitPoint(x: 0.20, y: 1.0),
                startRadius: 0,
                endRadius: 280
            )
            .blendMode(.multiply)
        }
        .saturation(1.05)
        .contrast(1.05)
    }

    private var angularRays: some View {
        let baseAngle = seededAngle(for: seed)
        return AngularGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color.white.opacity(0.18), location: 0.02),
                .init(color: .clear, location: 0.04),
                .init(color: .clear, location: 0.20),
                .init(color: Color.white.opacity(0.10), location: 0.22),
                .init(color: .clear, location: 0.24),
                .init(color: .clear, location: 0.45),
                .init(color: Color.white.opacity(0.16), location: 0.47),
                .init(color: .clear, location: 0.49),
                .init(color: .clear, location: 1.0)
            ],
            center: UnitPoint(x: 0.5, y: 1.1),
            angle: .degrees(baseAngle)
        )
        .blendMode(.screen)
        .opacity(0.55)
    }

    private var noiseOverlay: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: hashSeed(seed))
            let dotCount = 1800
            for _ in 0..<dotCount {
                let x = rng.nextDouble() * size.width
                let y = rng.nextDouble() * size.height
                let alpha = rng.nextDouble() * 0.55
                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                context.fill(Path(rect), with: .color(.black.opacity(alpha)))
            }
        }
        .blendMode(.overlay)
    }

    private func seededAngle(for seed: String) -> Double {
        var hash = 5381
        for ch in seed.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(ch.value)
        }
        return Double(abs(hash) % 90) + 180.0
    }

    private func hashSeed(_ seed: String) -> UInt64 {
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
