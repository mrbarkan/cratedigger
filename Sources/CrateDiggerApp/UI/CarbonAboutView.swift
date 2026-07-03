import AppKit
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
        // Head space so the eyebrow + icon bay clear the window's traffic lights
        // and the faceplate has room to breathe at the top.
        .padding(.top, 26)
    }

    // MARK: - Left bay

    @Environment(\.carbon) private var theme

    private var iconBay: some View {
        RecessedWell {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 150, height: 150)
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

            VStack(alignment: .leading, spacing: 12) {
                featureRow(dot: theme.cyan, label: "DIG",
                           desc: "Scan mixed folders into the Prep Crate and see what's really there.")
                featureRow(dot: theme.sun, label: "ORGANIZE",
                           desc: "File albums into crates; fix tags and artwork in the Inspector.")
                featureRow(dot: theme.orange, label: "CONVERT",
                           desc: "Batch-reshape chaotic rips into clean libraries with FFmpeg.")
                featureRow(dot: theme.indigo, label: "SPIN",
                           desc: "Play local files, CDs, streams, and YouTube radio — or split vinyl rips.")
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            Rectangle()
                .fill(theme.hair.opacity(theme.isDark ? 0.5 : 0.7))
                .frame(height: 1)

            HStack(spacing: 16) {
                linkButton("smash.mrbarkan.com", url: "https://smash.mrbarkan.com")
                linkButton("Send Feedback", url: "mailto:opa@mrbarkan.com?subject=CrateDigger%20Feedback")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("© 2026 MRBRKN SMASH")
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink4)
                    Text("Powered by FFmpeg · yt-dlp · AVFoundation")
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @Environment(\.openURL) private var openURL

    private func linkButton(_ title: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            Text(title)
                .font(CarbonFont.mono(11, weight: .semibold))
                .foregroundStyle(theme.cyan)
                .underline()
        }
        .buttonStyle(.plain)
        .pointerStyleLink()
    }

    // MARK: - OLED strip

    @State private var versionCopied = false

    /// Click to copy the version string — handy for bug reports.
    private var oledStrip: some View {
        // Text on the OLED is always light — it sits on a near-black surface in
        // both themes, so it uses fixed colours rather than theme.ink.
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: copyVersion) {
            shape
                .fill(theme.oledSurface)
                .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1))
                .overlay(
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(versionText)
                                .font(CarbonFont.mono(12.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(theme.orange)
                            Text(versionCopied ? "COPIED TO CLIPBOARD" : "CREATED BY MRBRKN SMASH · CLICK TO COPY")
                                .font(CarbonFont.mono(10, weight: .medium))
                                .tracking(1.4)
                                .foregroundStyle(versionCopied ? theme.cyan : Color.white.opacity(0.62))
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
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: versionCopied)
    }

    private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(versionText, forType: .string)
        versionCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            versionCopied = false
        }
    }

    private var versionText: String { AppVersion.currentDisplayString }

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
