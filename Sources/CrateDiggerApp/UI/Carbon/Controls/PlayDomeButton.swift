import SwiftUI

struct PlayDomeButton: View {
    @Environment(\.carbon) private var theme
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.orangeHi, theme.orange, theme.orangeLo],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: CarbonLayout.playButtonSize * 0.6
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                            .padding(0.5)
                    )
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.7 : 0.4), radius: 4, y: 3)
                    .shadow(color: theme.orange.opacity(isPlaying ? 0.6 : 0), radius: 16)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: CarbonLayout.playButtonSize * 0.32, weight: .black))
                    .foregroundStyle(Color.white)
            }
            .frame(width: CarbonLayout.playButtonSize, height: CarbonLayout.playButtonSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}
