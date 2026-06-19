import AppKit
import SwiftUI

private struct WindowDragGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VolumeKnob: View {
    @Environment(\.carbon) private var theme
    @Binding var value: Double  // 0...1

    @State private var dragStartValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("VOLUME")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
                Text(percentLabel)
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink2)
            }

            volumeTrack
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(WindowDragGuard())
                .gesture(dragGesture)
                .onTapGesture(count: 2) {
                    ClickPlayer.shared.play(.tick)
                    value = 0.8
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 154)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    private var percentLabel: String {
        String(format: "%02d", Int(value * 100))
    }

    private var volumeTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fillWidth = max(8, width * value)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.36 : 0.10))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.56), lineWidth: 0.6)
                    )
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan.opacity(0.92), theme.orange.opacity(0.88)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .shadow(color: theme.cyan.opacity(theme.isDark ? 0.26 : 0.18), radius: 6)
                Circle()
                    .fill(theme.chassisHi)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.70), lineWidth: 0.6))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.46 : 0.20), radius: 4, y: 2)
                    .offset(x: min(max(fillWidth - 8, 0), width - 16))
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = dragStartValue ?? value
                if dragStartValue == nil { dragStartValue = start }
                let delta = gesture.translation.width / 120.0
                value = min(max(start + delta, 0), 1)
            }
            .onEnded { _ in dragStartValue = nil }
    }
}
