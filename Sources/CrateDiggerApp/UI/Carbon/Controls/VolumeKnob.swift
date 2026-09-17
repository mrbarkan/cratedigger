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
            // Label on the right: the two faders mirror each other around the
            // transport, POSITION's label on its outer edge and so this one.
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Text("VOLUME")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
            }
            .frame(height: 12)   // fixed label-row height: the footer pods share one text line

            Spacer(minLength: 0)

            FaderTrack(
                progress: value,
                detents: [FaderDetent(fraction: Self.unityFraction, label: "0dB")],
                onScrub: { raw in
                    // Magnetically snap to the 0 dB (unity) detent when close.
                    value = abs(raw - Self.unityFraction) < 0.025 ? Self.unityFraction : raw
                }
            )
            .frame(height: 27)   // same content-box height as the EQ/VU LCDs so rail and LCD centers match
            .background(WindowDragGuard())
            .onTapGesture(count: 2) {
                ClickPlayer.shared.play(.tick)
                value = Self.unityFraction   // double-tap → unity (0 dB)
            }
        }
        .padding(.vertical, 9)   // matches the other footer pod so their labels align
        .padding(.horizontal, 12)
        .frame(minWidth: 184, maxWidth: 380, minHeight: 64, maxHeight: 64)   // same travel as POSITION, like a mixer
        // No pod: the fader sits straight in the shelf, like a mixer's.
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
