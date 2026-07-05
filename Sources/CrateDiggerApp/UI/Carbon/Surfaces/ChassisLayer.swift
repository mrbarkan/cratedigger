import SwiftUI

struct ChassisLayer<Content: View>: View {
    @Environment(\.carbon) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            GoldenGateBackdrop()
            chassisPlate
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var chassisPlate: some View {
        let shape = RoundedRectangle(cornerRadius: CarbonLayout.chassisCornerRadius, style: .continuous)
        return ZStack {
            // Opaque base coat, NOT a Material. SwiftUI Materials become
            // CABackdropLayer live blurs that WindowServer re-samples every
            // frame — the app idled at ~60% GPU with 12 of them. The gradient
            // overlays below carry the Carbon look; keep these fills opaque.
            shape
                .fill(theme.chassis)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.chassisHi.opacity(theme.isDark ? 0.28 : 0.54),
                                theme.chassis.opacity(theme.isDark ? 0.30 : 0.44),
                                theme.chassisLo.opacity(theme.isDark ? 0.36 : 0.34)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.18 : 0.76),
                                theme.hair.opacity(theme.isDark ? 0.45 : 0.58),
                                Color.black.opacity(theme.isDark ? 0.44 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.isDark ? 0.05 : 0.42),
                            Color.clear,
                            Color.black.opacity(theme.isDark ? 0.22 : 0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: theme.shadow2.color, radius: theme.shadow2.radius, x: theme.shadow2.x, y: theme.shadow2.y)

            content()
                .padding(.horizontal, CarbonLayout.chassisInsetH)
                .padding(.vertical, CarbonLayout.chassisInsetV)
        }
        .compositingGroup()
    }
}

private struct GoldenGateBackdrop: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.backgroundBase)
            LinearGradient(
                colors: [theme.backgroundGradientStart, theme.backgroundBase, theme.backgroundGradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(theme.isDark ? 0.82 : 0.92)
            GeometryReader { proxy in
                let span = max(proxy.size.width, proxy.size.height)
                ZStack {
                    diagonalBand(
                        span: span,
                        width: span * 0.34,
                        colors: [
                            Color.clear,
                            theme.orange.opacity(theme.isDark ? 0.14 : 0.18),
                            Color.clear
                        ],
                        angle: -28,
                        x: -span * 0.26,
                        y: span * 0.18
                    )
                    diagonalBand(
                        span: span,
                        width: span * 0.42,
                        colors: [
                            Color.clear,
                            theme.cyan.opacity(theme.isDark ? 0.12 : 0.16),
                            Color.clear
                        ],
                        angle: -28,
                        x: span * 0.30,
                        y: -span * 0.22
                    )
                    diagonalBand(
                        span: span,
                        width: span * 0.22,
                        colors: [
                            Color.clear,
                            theme.indigo.opacity(theme.isDark ? 0.10 : 0.12),
                            Color.clear
                        ],
                        angle: 18,
                        x: span * 0.06,
                        y: span * 0.32
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            Rectangle()
                .fill(theme.backgroundBase)
                .opacity(theme.isDark ? 0.16 : 0.24)
            LinearGradient(
                colors: [
                    Color.white.opacity(theme.isDark ? 0.02 : 0.28),
                    Color.clear,
                    Color.black.opacity(theme.isDark ? 0.26 : 0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func diagonalBand(
        span: CGFloat,
        width: CGFloat,
        colors: [Color],
        angle: Double,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: span * 1.75)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }
}
