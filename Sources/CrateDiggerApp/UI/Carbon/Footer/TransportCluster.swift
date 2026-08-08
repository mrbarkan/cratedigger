import SwiftUI

struct TransportCluster: View {
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            transportButton(systemName: "scope", label: "Go to Current Song (⌘L)") {
                model.revealNowPlaying()
            }
            .disabled(model.nowPlayingTrack == nil)
            .opacity(model.nowPlayingTrack == nil ? 0.45 : 1)
            toggleButton(systemName: "shuffle", on: model.shuffleEnabled, label: "Shuffle") {
                model.toggleShuffle()
            }
            transportButton(systemName: "backward.end.fill", label: "Previous track") { model.previous() }
            transportButton(systemName: "gobackward.10", label: "Rewind 8 seconds") { model.rewind8s() }
            PlayDomeButton(isPlaying: model.playbackState == .playing) {
                model.togglePlayPause()
            }
            transportButton(systemName: "goforward.10", label: "Forward 8 seconds") { model.forward8s() }
            transportButton(systemName: "forward.end.fill", label: "Next track") { model.next() }
            toggleButton(systemName: repeatIcon, on: model.repeatMode != .off, label: "Repeat") {
                model.cycleRepeatMode()
            }
        }
    }

    private var repeatIcon: String {
        model.repeatMode == .one ? "repeat.1" : "repeat"
    }

    /// Shuffle / repeat toggle — the same silicone cap as the plain transport
    /// keys, with the LED behind it lit while the mode is on.
    private func toggleButton(systemName: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            cap(systemName: systemName, lit: on)
        }
        .buttonStyle(.carbonHover)
        .carbonTip(label)
        .accessibilityLabel(label)
    }

    private func transportButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            cap(systemName: systemName, lit: false)
        }
        .buttonStyle(.carbonHover)
        .carbonTip(label)
        .accessibilityLabel(label)
    }

    private func cap(systemName: String, lit: Bool) -> some View {
        SiliconeCap(shape: RoundedRectangle(cornerRadius: 12, style: .continuous), lit: lit) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))   // same size as the dome's ⏯
        }
        .frame(width: geometry.transportButtonSize, height: geometry.transportButtonSize)
    }
}
