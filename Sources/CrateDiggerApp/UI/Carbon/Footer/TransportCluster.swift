import SwiftUI

struct TransportCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
        Button(action: action) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 11)

                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink2)
            }
            .frame(width: CarbonLayout.transportButtonSize, height: CarbonLayout.transportButtonSize)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
