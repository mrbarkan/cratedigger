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
        VStack(spacing: 4) {
            ZStack {
                tickRing
                rim
                knurling
                centerCap
                marker
                Circle()
                    .fill(theme.orange)
                    .frame(width: 4, height: 4)
                    .offset(y: -CarbonLayout.volumeKnobSize * 0.30)
                    .shadow(color: theme.orange, radius: 3)
                    .rotationEffect(rotationAngle)
            }
            .frame(width: CarbonLayout.volumeKnobSize, height: CarbonLayout.volumeKnobSize)
            .contentShape(Circle())
            .background(WindowDragGuard())
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                value = 0.8
            }
            .accessibilityValue("\(Int(value * 100)) percent")

            Text("VOLUME · \(Int(value * 100))")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink2)
        }
    }

    private var rotationAngle: Angle {
        // -135° at 0, +135° at 1
        let degrees = (value - 0.5) * 270
        return Angle(degrees: degrees)
    }

    private var rim: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: theme.isDark
                        ? [Color(hex: 0x6E6C66), Color(hex: 0x4A4844), Color(hex: 0x2A2825)]
                        : [Color(hex: 0xFBF7EC), theme.metal, theme.metalLo],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 0,
                    endRadius: CarbonLayout.volumeKnobSize * 0.55
                )
            )
            .overlay(
                Circle().stroke(Color.black.opacity(theme.isDark ? 0.6 : 0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.18), radius: 4, y: 3)
    }

    private var knurling: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerR = size.width / 2 - 2
            let innerR = outerR * 0.78
            let dashCount = 96
            for i in 0..<dashCount {
                let angle = Double(i) / Double(dashCount) * 2 * .pi
                let alpha: Double = i % 2 == 0 ? 0.18 : 0.42
                let p1 = CGPoint(x: c.x + cos(angle) * innerR, y: c.y + sin(angle) * innerR)
                let p2 = CGPoint(x: c.x + cos(angle) * outerR, y: c.y + sin(angle) * outerR)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.black.opacity(alpha)), lineWidth: 0.5)
            }
        }
        .blendMode(theme.isDark ? .screen : .multiply)
        .opacity(0.6)
    }

    private var centerCap: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: theme.isDark
                        ? [Color(hex: 0x3A3833), Color(hex: 0x1A1A18), Color(hex: 0x0E0E0C)]
                        : [.white, theme.chassis, theme.chassisDeep],
                    center: UnitPoint(x: 0.30, y: 0.25),
                    startRadius: 0,
                    endRadius: CarbonLayout.volumeKnobSize * 0.30
                )
            )
            .overlay(Circle().stroke(Color.black.opacity(0.20), lineWidth: 0.5))
            .frame(
                width: CarbonLayout.volumeKnobSize * 0.62,
                height: CarbonLayout.volumeKnobSize * 0.62
            )
    }

    private var marker: some View {
        Capsule()
            .fill(theme.isDark ? theme.ink : Color(hex: 0x242423))
            .frame(width: 3, height: CarbonLayout.volumeKnobSize * 0.18)
            .offset(y: -CarbonLayout.volumeKnobSize * 0.30)
            .rotationEffect(rotationAngle)
    }

    private var tickRing: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2 + 4
            let positions: [Double] = stride(from: -135.0, through: 135.0, by: 67.5).map { $0 }
            for deg in positions {
                let theta = (deg - 90) * .pi / 180
                let p1 = CGPoint(x: c.x + cos(theta) * r, y: c.y + sin(theta) * r)
                let p2 = CGPoint(x: c.x + cos(theta) * (r + 4), y: c.y + sin(theta) * (r + 4))
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(theme.ink3), lineWidth: 1)
            }
        }
        .frame(
            width: CarbonLayout.volumeKnobSize + 16,
            height: CarbonLayout.volumeKnobSize + 16
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = dragStartValue ?? value
                if dragStartValue == nil { dragStartValue = start }
                let delta = -gesture.translation.height / 200.0
                value = min(max(start + delta, 0), 1)
            }
            .onEnded { _ in dragStartValue = nil }
    }
}
