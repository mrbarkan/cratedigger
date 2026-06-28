import AppKit
import SwiftUI

struct VolumeKnob: View {
    @Environment(\.carbon) private var theme
    @Binding var value: Double  // 0...1

    @State private var dragStartValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("VOLUME")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

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
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    private var volumeTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let frac = min(max(value, 0), 1)
            // A thin rail with a knob that rides proud of it. The knob is larger
            // than the line (the user wanted the knob bigger, the line thinner).
            let lineHeight: CGFloat = 6
            let knobSize: CGFloat = 18
            // The knob centre travels between the two end stops; the coloured fill
            // is revealed up to the knob centre.
            let travel = max(width - knobSize, 0)
            let knobCentreX = knobSize / 2 + travel * frac
            ZStack(alignment: .leading) {
                // Recessed rail (the "line").
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.36 : 0.10))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.56), lineWidth: 0.5)
                    )
                    .frame(width: width, height: lineHeight)

                // A FIXED cyan→orange gradient mapped across the full rail width,
                // then revealed up to the knob via a mask. The colour at any point
                // is constant — turning the volume up just uncovers more of the
                // same gradient instead of stretching/compressing it.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan.opacity(0.92), theme.orange.opacity(0.88)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width, height: lineHeight)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: knobCentreX, height: lineHeight)
                    }
                    .shadow(color: theme.cyan.opacity(theme.isDark ? 0.26 : 0.18), radius: 6)

                // Knob — larger than the rail, sits proud of it.
                Circle()
                    .fill(theme.chassisHi)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(Circle().stroke(Color.white.opacity(0.70), lineWidth: 0.6))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.46 : 0.20), radius: 4, y: 2)
                    .offset(x: knobCentreX - knobSize / 2)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
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
