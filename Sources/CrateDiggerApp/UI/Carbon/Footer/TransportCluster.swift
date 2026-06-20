import SwiftUI

struct TransportCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            toggleButton(systemName: "shuffle", on: model.shuffleEnabled, label: "Shuffle") {
                model.toggleShuffle()
            }
            transportButton(systemName: "backward.end.fill", label: "Prev") { model.previous() }
            transportButton(systemName: "gobackward.10", label: "Rew") { model.rewind8s() }
            PlayDomeButton(isPlaying: model.playbackState == .playing) {
                model.togglePlayPause()
            }
            transportButton(systemName: "goforward.10", label: "Fwd") { model.forward8s() }
            transportButton(systemName: "forward.end.fill", label: "Next") { model.next() }
            toggleButton(systemName: repeatIcon, on: model.repeatMode != .off, label: "Repeat") {
                model.cycleRepeatMode()
            }
        }
    }

    private var repeatIcon: String {
        model.repeatMode == .one ? "repeat.1" : "repeat"
    }

    /// Shuffle / repeat toggle (CrateDigger v6 `.tb.tog`) — orange icon + glow when on.
    private func toggleButton(systemName: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 11)
                if on {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(theme.orange.opacity(0.5), lineWidth: 1)
                }
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? theme.orange : theme.ink3)
            }
            .frame(width: 42, height: 42)
            .shadow(color: on ? theme.orange.opacity(0.4) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
