import SwiftUI

/// Footer left cluster (CrateDigger v6 `.f-left`): the VU meter + POSITION dial.
/// The VU bars are driven by the real audio signal via the playback engine's
/// audio tap (polled while playing).
struct FooterLeftCluster: View {
    @EnvironmentObject private var model: LibraryViewModel
    @StateObject private var meters = MeterDriver()
    @AppStorage("cratedigger.meter.simpleHorizontalVU") private var simpleHorizontalVU = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if simpleHorizontalVU {
                    HorizontalLEDMeter(leftLevel: meters.leftLevel, rightLevel: meters.rightLevel)
                } else {
                    LEDMeterPair(bands: meters.bands)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { simpleHorizontalVU.toggle() }
            .carbonTip("Click to switch L/R ↔ Spectrum")
            PositionDial()
        }
        .onAppear {
            meters.levelsProvider = { [weak model] in model?.currentPlaybackLevels() ?? (left: 0, right: 0) }
            meters.spectrumProvider = { [weak model] in model?.currentPlaybackSpectrum() ?? [] }
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
