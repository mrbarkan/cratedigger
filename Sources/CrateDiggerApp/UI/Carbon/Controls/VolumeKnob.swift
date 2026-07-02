import AppKit
import CrateDiggerCore
import SwiftUI

struct VolumeKnob: View {
    @Environment(\.carbon) private var theme
    @Binding var value: Double  // 0...1

    /// Unity (0 dB) sits at ~92% of travel under the v10 volume law
    /// (dB = −60 + pct·65); the embossed "0" mark lives there.
    private static let unityFraction = VolumeCurve.unityPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("VOLUME")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            FaderTrack(
                progress: value,
                detents: [FaderDetent(fraction: Self.unityFraction, label: "0")],
                onScrub: { raw in
                    // Magnetically snap to the 0 dB (unity) detent when close.
                    value = abs(raw - Self.unityFraction) < 0.025 ? Self.unityFraction : raw
                }
            )
            .frame(height: 26)
            .background(WindowDragGuard())
            .onTapGesture(count: 2) {
                ClickPlayer.shared.play(.tick)
                value = Self.unityFraction   // double-tap → unity (0 dB)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .padding(.horizontal, 12)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
