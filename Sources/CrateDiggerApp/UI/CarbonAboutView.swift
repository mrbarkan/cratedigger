import SwiftUI

/// The About screen, rebuilt as a Carbon hardware faceplate hosted in the About
/// window via `NSHostingController`. Reuses the app's Carbon theme + components
/// so it matches the main UI and follows the light/dark appearance. Replaces the
/// old light "design-package" layout (BrandArtworkView et al.).
struct CarbonAboutView: View {
    /// A concrete light/dark mode resolved by the window controller (never
    /// `.system`), so the Carbon theme can't disagree with the window's
    /// materials — a freshly-created hosting view otherwise resolves `.system`
    /// to light while the materials follow the real (dark) appearance.
    let mode: AppearanceMode

    var body: some View {
        ChassisLayer { faceplate }
            .frame(minWidth: 700, minHeight: 440)
            .carbonThemed(mode: mode)
    }

    private var faceplate: some View {
        HStack(alignment: .top, spacing: 22) {
            iconBay
            infoColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Left bay

    @Environment(\.carbon) private var theme

    private var iconBay: some View {
        RecessedWell {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                CarbonChassisIconView(size: 150)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
                Text("CARBON CHASSIS")
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 226)
    }

    // MARK: - Right column

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MODERN-RETRO AUDIO WORKBENCH")
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(theme.cyan)

            Text("CrateDigger")
                .font(CarbonFont.sans(30, weight: .bold))
                .foregroundStyle(theme.ink)

            Text("A modern-retro workstation for scanning, previewing, and cleaning up unruly music libraries.")
                .font(CarbonFont.sans(13))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            oledStrip

            VStack(alignment: .leading, spacing: 14) {
                featureRow(dot: theme.cyan, label: "SCAN",
                           desc: "Browse mixed folders and see what's there.")
                featureRow(dot: theme.sun, label: "PREVIEW",
                           desc: "Artwork, metadata, and playback together.")
                featureRow(dot: theme.orange, label: "CONVERT",
                           desc: "Reshape chaotic folders into clean libraries.")
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            Rectangle()
                .fill(theme.hair.opacity(theme.isDark ? 0.5 : 0.7))
                .frame(height: 1)

            HStack {
                Button { openURL(URL(string: "https://smash.mrbarkan.com")!) } label: {
                    Text("smash.mrbarkan.com")
                        .font(CarbonFont.mono(12, weight: .semibold))
                        .foregroundStyle(theme.cyan)
                        .underline()
                }
                .buttonStyle(.plain)
                .pointerStyleLink()
                Spacer()
                Text("macOS · Swift · AppKit · FFmpeg")
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(theme.ink4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @Environment(\.openURL) private var openURL

    // MARK: - OLED strip

    private var oledStrip: some View {
        // Text on the OLED is always light — it sits on a near-black surface in
        // both themes, so it uses fixed colours rather than theme.ink.
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(theme.oledSurface)
            .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1))
            .overlay(
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(versionText)
                            .font(CarbonFont.mono(12.5, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(theme.orange)
                        Text("CREATED BY MRBRKN SMASH")
                            .font(CarbonFont.mono(10, weight: .medium))
                            .tracking(1.4)
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer(minLength: 0)
                    Circle()
                        .fill(theme.cyan)
                        .frame(width: 7, height: 7)
                        .shadow(color: theme.cyan.opacity(0.85), radius: 4)
                }
                .padding(.horizontal, 16)
            )
            .frame(height: 54)
    }

    private var versionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? AppVersion.build
        return AppVersion.displayString(version: version, build: build)
    }

    private func featureRow(dot: Color, label: String, desc: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .shadow(color: dot.opacity(0.7), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CarbonFont.mono(11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink)
                Text(desc)
                    .font(CarbonFont.sans(12))
                    .foregroundStyle(theme.ink3)
            }
        }
    }
}

private extension View {
    /// Pointing-hand cursor on hover for the link (no-op pre-macOS 15).
    @ViewBuilder func pointerStyleLink() -> some View {
        if #available(macOS 15.0, *) { self.pointerStyle(.link) } else { self }
    }
}

/// A faithful vector rendition of the Carbon-chassis app icon — graphite
/// squircle, OLED meter row, cyan LED, and a vinyl disc with an orange spindle.
/// Drawn rather than bundled so it stays crisp and needs no resource plumbing.
struct CarbonChassisIconView: View {
    var size: CGFloat

    private let orange = Color(hex: 0xFF6236)
    private let cyan = Color(hex: 0x35C4D6)

    var body: some View {
        let s = size
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x262626), Color(hex: 0x161616), Color(hex: 0x0A0A0A)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: max(1, s * 0.006))
                )

            HStack(spacing: s * 0.028) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: s * 0.012, style: .continuous)
                        .fill(i < 3 ? orange : Color(hex: 0x3A3A3A))
                        .frame(width: s * 0.085, height: s * 0.052)
                }
            }
            .offset(x: -s * 0.055, y: -s * 0.30)

            Circle()
                .fill(cyan)
                .frame(width: s * 0.055, height: s * 0.055)
                .shadow(color: cyan.opacity(0.85), radius: s * 0.03)
                .offset(x: s * 0.30, y: -s * 0.30)

            ZStack {
                Circle().fill(RadialGradient(
                    colors: [Color(hex: 0x151515), Color(hex: 0x0B0B0B)],
                    center: .center, startRadius: 0, endRadius: s * 0.26))
                Circle().stroke(Color.white.opacity(0.05), lineWidth: max(1, s * 0.004))
                    .frame(width: s * 0.40, height: s * 0.40)
                Circle().stroke(Color.white.opacity(0.05), lineWidth: max(1, s * 0.004))
                    .frame(width: s * 0.30, height: s * 0.30)
                Circle().fill(orange).frame(width: s * 0.09, height: s * 0.09)
                Circle().fill(Color(hex: 0x0A0A0A)).frame(width: s * 0.03, height: s * 0.03)
            }
            .frame(width: s * 0.52, height: s * 0.52)
            .offset(y: s * 0.06)
        }
        .frame(width: s, height: s)
    }
}
