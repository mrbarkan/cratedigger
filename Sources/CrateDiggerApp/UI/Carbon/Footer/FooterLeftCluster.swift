import SwiftUI

/// Footer left cluster (CrateDigger v6 `.f-left`): the VU meter + POSITION dial.
/// The VU bars are driven by the real audio signal via the playback engine's
/// audio tap (polled while playing).
struct FooterLeftCluster: View {
    @EnvironmentObject private var model: LibraryViewModel
    @StateObject private var meters = MeterDriver()

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LEDMeterPair(leftLevel: meters.leftLevel, rightLevel: meters.rightLevel)
            PositionDial()
        }
        .onAppear {
            meters.levelsProvider = { [weak model] in model?.currentPlaybackLevels() ?? (left: 0, right: 0) }
            syncMeterRunning()
        }
        .onChange(of: model.playbackState) { _ in
            syncMeterRunning()
        }
    }

    private func syncMeterRunning() {
        if model.playbackState == .playing {
            meters.start()
        } else {
            meters.stop()
        }
    }
}
