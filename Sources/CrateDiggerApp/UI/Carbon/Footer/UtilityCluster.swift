import SwiftUI

/// Footer right cluster (CrateDigger v6 `.f-util`): volume control + EQ LCD.
struct UtilityCluster: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VolumeKnob(value: $model.playbackVolume)
            EQScreen()
        }
    }
}
