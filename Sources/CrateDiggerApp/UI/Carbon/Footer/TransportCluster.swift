import SwiftUI

struct TransportCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            transportButton(systemName: "backward.end.fill", label: "Prev") { model.previous() }
            transportButton(systemName: "gobackward.10", label: "Rew") { model.rewind8s() }
            PlayDomeButton(isPlaying: model.playbackState == .playing) {
                model.togglePlayPause()
            }
            transportButton(systemName: "goforward.10", label: "Fwd") { model.forward8s() }
            transportButton(systemName: "forward.end.fill", label: "Next") { model.next() }
        }
    }

    private func transportButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: theme.isDark
                                    ? [Color(hex: 0x3A3A37), Color(hex: 0x2A2A28), Color(hex: 0x1A1A18)]
                                    : [theme.chassisHi, theme.chassis, theme.chassisLo],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(theme.isDark ? 0.05 : 0.5), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.18), radius: 2, y: 2)

                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                }
                .frame(width: CarbonLayout.transportButtonSize, height: CarbonLayout.transportButtonSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

            Text(label.uppercased())
                .font(CarbonFont.mono(8, weight: .semibold))
                .tracking(2)
                .foregroundStyle(theme.ink3)
        }
    }
}
