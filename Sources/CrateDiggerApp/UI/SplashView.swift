import SwiftUI

/// Launch splash: a small Carbon faceplate card shown in a borderless window
/// while the main window warms up (see `SplashWindowController`). Purely
/// decorative — the fake "boot sequence" runs on a fixed clock and the window
/// is faded out by the app delegate once the main window is on screen.
struct SplashView: View {
    /// Concrete light/dark resolved by the window controller (see CarbonAboutView).
    let mode: AppearanceMode

    var body: some View {
        SplashCard()
            .frame(width: 520, height: 340)
            .carbonThemed(mode: mode)
    }
}

private struct SplashCard: View {
    @Environment(\.carbon) private var theme

    @State private var progress: CGFloat = 0
    @State private var bootLineIndex = 0
    @State private var markVisible = false

    private static let bootLines = [
        "CALIBRATING TONE ARM",
        "WARMING UP THE CHASSIS",
        "DUSTING OFF THE CRATES",
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            BrandMark(size: 92)
                .scaleEffect(markVisible ? 1 : 0.86)
                .opacity(markVisible ? 1 : 0)

            VStack(spacing: 8) {
                Text("CrateDigger")
                    .font(CarbonFont.sans(32, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("MODERN-RETRO AUDIO WORKBENCH")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(2.6)
                    .foregroundStyle(theme.cyan)
            }
            .padding(.top, 18)
            .opacity(markVisible ? 1 : 0)

            Spacer(minLength: 0)

            bootStrip
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chassisSurface(shape))
        .overlay(alignment: .topLeading) { ScrewHead().padding(14) }
        .overlay(alignment: .topTrailing) { ScrewHead().padding(14) }
        .overlay(alignment: .bottomLeading) { ScrewHead().padding(14) }
        .overlay(alignment: .bottomTrailing) { ScrewHead().padding(14) }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(theme.isDark ? 0.20 : 0.80),
                        theme.hair.opacity(theme.isDark ? 0.50 : 0.60),
                        Color.black.opacity(theme.isDark ? 0.50 : 0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
        .compositingGroup()
        .shadow(color: theme.shadow2.color, radius: theme.shadow2.radius,
                x: theme.shadow2.x, y: theme.shadow2.y)
        .onAppear(perform: startBootSequence)
    }

    private func chassisSurface(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [theme.chassisHi, theme.chassis, theme.chassisLo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(theme.isDark ? 0.05 : 0.40),
                        Color.clear,
                        Color.black.opacity(theme.isDark ? 0.24 : 0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    // MARK: - OLED boot strip

    private var bootStrip: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(theme.oledSurface)
            .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1))
            .overlay(
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(Self.bootLines[bootLineIndex])
                            .font(CarbonFont.mono(10.5, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(theme.orange)
                            .id(bootLineIndex)
                            .transition(.opacity)
                        Spacer(minLength: 0)
                        Text(versionText)
                            .font(CarbonFont.mono(9))
                            .tracking(1.2)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    ledProgress
                }
                .padding(.horizontal, 16)
            )
            .frame(height: 62)
            .animation(.easeInOut(duration: 0.18), value: bootLineIndex)
    }

    /// A row of LED segments filling left-to-right with `progress`.
    private var ledProgress: some View {
        let segments = 26
        return HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = CGFloat(index) / CGFloat(segments) < progress
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? theme.cyan : Color.white.opacity(0.10))
                    .frame(height: 6)
                    .shadow(color: lit ? theme.cyan.opacity(0.7) : .clear, radius: 3)
            }
        }
    }

    private var versionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? AppVersion.build
        return AppVersion.displayString(version: version, build: build)
    }

    private func startBootSequence() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            markVisible = true
        }
        withAnimation(.easeInOut(duration: 1.45)) {
            progress = 1
        }
        Task { @MainActor in
            for index in 1..<Self.bootLines.count {
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                bootLineIndex = index
            }
        }
    }
}

/// A small decorative chassis screw for the splash card corners.
private struct ScrewHead: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.metalHi, theme.metal, theme.metalLo],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: 7
                    )
                )
            Rectangle()
                .fill(Color.black.opacity(theme.isDark ? 0.55 : 0.35))
                .frame(width: 7, height: 1.2)
                .rotationEffect(.degrees(-38))
        }
        .frame(width: 10, height: 10)
        .overlay(Circle().strokeBorder(Color.black.opacity(theme.isDark ? 0.45 : 0.18), lineWidth: 0.5))
    }
}
