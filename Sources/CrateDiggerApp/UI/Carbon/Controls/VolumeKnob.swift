import AppKit
import CrateDiggerCore
import SwiftUI

/// A footer fader pod: a printed label, an optional key beside it, and a fader
/// with a magnetic unity mark. VOLUME is the default; AMBIENT passes its own
/// label, law and key.
struct VolumeKnob<Accessory: View>: View {
    @Environment(\.carbon) private var theme
    @Binding var value: Double  // 0...1
    var label = "VOLUME"
    /// Where the embossed "0" sits. VOLUME's unity (0 dB) is at ~92% of travel
    /// under the v10 volume law (dB = −60 + pct·65).
    var unityFraction = VolumeCurve.unityPosition
    var accessibilityName = "Volume"
    var width: CGFloat = 184
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(label)
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
                accessory()
            }
            .frame(height: 12)   // fixed label-row height: all four footer pods share one text line

            Spacer(minLength: 0)

            FaderTrack(
                progress: value,
                detents: [FaderDetent(fraction: unityFraction, label: "0")],
                onScrub: { raw in
                    // Magnetically snap to the unity detent when close.
                    value = abs(raw - unityFraction) < 0.025 ? unityFraction : raw
                }
            )
            .frame(height: 27)   // same content-box height as the EQ/VU LCDs so rail and LCD centers match
            .background(WindowDragGuard())
            .onTapGesture(count: 2) {
                ClickPlayer.shared.play(.tick)
                value = unityFraction   // double-tap → unity (0 dB)
            }
        }
        .padding(.vertical, 9)   // matches EQScreen/LEDMeter so the four footer panels' labels align
        .padding(.horizontal, 12)
        .frame(width: width, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

extension VolumeKnob where Accessory == EmptyView {
    init(value: Binding<Double>) {
        self.init(value: value, accessory: { EmptyView() })
    }
}
