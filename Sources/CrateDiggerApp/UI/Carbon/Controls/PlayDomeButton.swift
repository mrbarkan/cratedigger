import SwiftUI

/// The transport dome, played straight as hardware: one printed ⏯ glyph that
/// never changes — the *backlight* is the state. Dark dome + pitch-black
/// print when paused; theme-lit dome with the print in the accent's dark
/// shade when playing, like light coming up under an engraved key.
struct PlayDomeButton: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    let isPlaying: Bool
    let action: () -> Void

    /// Unlit dome finish — a fixed hardware material (same family as the VU
    /// LEDs and patch-bay steel: deliberately not themeable).
    private static let domeOff: [Color] = [Color(white: 0.30), Color(white: 0.16), Color(white: 0.07)]

    var body: some View {
        Button(action: {
            ClickPlayer.shared.play(.firm)
            action()
        }) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isPlaying ? [theme.orangeHi, theme.orange, theme.orangeLo] : Self.domeOff,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(isPlaying ? 0.34 : 0.16), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(1)
                    )
                    .overlay(Circle().stroke(Color.white.opacity(isPlaying ? 0.42 : 0.20), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.58 : 0.24), radius: 9, y: 5)
                    .shadow(color: theme.orange.opacity(isPlaying ? 0.56 : 0), radius: 18)

                Image(systemName: "playpause.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(isPlaying ? theme.orangeLo : Color.black)
            }
            .frame(width: geometry.playButtonSize, height: geometry.playButtonSize)
        }
        .buttonStyle(.carbonHover)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}
