import AppKit
import SwiftUI

/// Stops a click-drag inside the scrub track from moving the borderless window.
private struct FooterDragGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Footer POSITION seek dial — same panel chrome as the volume control.
/// Reflects playback progress and scrubs to seek (CrateDigger v6 `.f-seek`).
struct PositionDial: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @State private var scrub: Double?

    private var progress: Double {
        if let scrub { return scrub }
        guard model.playbackDuration > 0 else { return 0 }
        return min(max(model.playbackCurrentTime / model.playbackDuration, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("POSITION")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            track
                .frame(height: 22)
                .background(FooterDragGuard())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityLabel("Playback position")
    }

    private var track: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.36 : 0.10))
                    .overlay(Capsule().stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.50), lineWidth: 0.6))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan.opacity(0.92), theme.orange.opacity(0.90)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, w * p), height: 6)
                    .shadow(color: theme.cyan.opacity(theme.isDark ? 0.26 : 0.18), radius: 5)
                Circle()
                    .fill(theme.chassisHi)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.70), lineWidth: 0.6))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.46 : 0.20), radius: 4, y: 2)
                    .offset(x: min(max(w * p - 8, 0), w - 16))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in scrub = min(max(g.location.x / w, 0), 1) }
                    .onEnded { g in
                        let f = min(max(g.location.x / w, 0), 1)
                        scrub = nil
                        ClickPlayer.shared.play(.tick)
                        model.seek(toFraction: f)
                    }
            )
        }
    }
}
