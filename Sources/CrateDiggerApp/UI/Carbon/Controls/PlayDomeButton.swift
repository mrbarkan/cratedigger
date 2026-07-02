import SwiftUI

struct PlayDomeButton: View {
    @Environment(\.carbon) private var theme
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            ClickPlayer.shared.play(.firm)
            action()
        }) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.orangeHi, theme.orange, theme.orangeLo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.34), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(1)
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.58 : 0.24), radius: 9, y: 5)
                    .shadow(color: theme.orange.opacity(isPlaying ? 0.56 : 0.24), radius: isPlaying ? 18 : 10)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(Color.white)
            }
            .frame(width: CarbonLayout.playButtonSize, height: CarbonLayout.playButtonSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}
