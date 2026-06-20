import SwiftUI

/// Footer left cluster (CrateDigger v6 `.f-left`): the VU meter + POSITION dial.
/// Owns the meter simulator that the VU bars animate from during playback.
struct FooterLeftCluster: View {
    @EnvironmentObject private var model: LibraryViewModel
    @StateObject private var meters = MeterSimulator()

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LEDMeterPair(leftLevel: meters.leftLevel, rightLevel: meters.rightLevel)
            PositionDial()
        }
        .onAppear {
            meters.volume = model.playbackVolume
            syncMeterRunning()
        }
        .onChange(of: model.playbackState) { _ in
            syncMeterRunning()
        }
        .onChange(of: model.playbackVolume) { newValue in
            meters.volume = newValue
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
