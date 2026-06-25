import SwiftUI

/// Footer right cluster (CrateDigger v6 `.f-util`): mini-player launch + volume
/// control + EQ LCD.
struct UtilityCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            miniPlayerButton
            VolumeKnob(value: $model.playbackVolume)
            EQScreen()
        }
    }

    private var miniPlayerButton: some View {
        Button(action: {
            ClickPlayer.shared.play(.key)
            NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
        }) {
            Image(systemName: "pip.enter")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .frame(width: 30, height: 30)
                .background(ChromeChassis(theme: theme, cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .carbonTip("Open the mini player")
    }
}
