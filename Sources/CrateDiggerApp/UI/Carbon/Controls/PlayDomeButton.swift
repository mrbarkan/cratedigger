import SwiftUI

/// The transport dome — the same moulded `SiliconeCap` as the rest of the
/// transport row, just round and one size up. The ⏯ print never changes; the
/// LED behind the cap is the state.
struct PlayDomeButton: View {
    @Environment(\.carbonGeometry) private var geometry
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            ClickPlayer.shared.play(.firm)
            action()
        }) {
            SiliconeCap(shape: Circle(), lit: isPlaying) {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 24, weight: .black))
            }
            .frame(width: geometry.playButtonSize, height: geometry.playButtonSize)
        }
        .buttonStyle(.carbonHover)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}
