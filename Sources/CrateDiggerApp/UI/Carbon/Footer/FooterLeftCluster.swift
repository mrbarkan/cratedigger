import SwiftUI

/// Footer left cluster (CrateDigger v6 `.f-left`): the VU meter + POSITION dial.
/// The VU bars are driven by the real audio signal via the playback engine's
/// audio tap (polled while playing).
struct FooterLeftCluster: View {
    @EnvironmentObject private var model: LibraryViewModel
    // Deliberately @State, not @StateObject: the cluster must NOT observe the
    // driver, or every meter tick re-renders the dial/fader/drag-guard too.
    // Only the leaf MeterCluster below subscribes. @State still keeps one
    // instance alive across renders.
    @State private var meters = MeterDriver()
    @AppStorage("cratedigger.meter.simpleHorizontalVU") private var simpleHorizontalVU = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MeterCluster(meters: meters, simple: simpleHorizontalVU)
                .contentShape(Rectangle())
                .onTapGesture { simpleHorizontalVU.toggle() }
                .carbonTip("Click to switch L/R ↔ Spectrum")
            PositionDial(clock: model.playbackClock)
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

/// Leaf view that actually observes the meter driver, so per-tick publishes
/// re-render just the LEDs — not the whole footer cluster.
private struct MeterCluster: View {
    @ObservedObject var meters: MeterDriver
    let simple: Bool

    var body: some View {
        if simple {
            HorizontalLEDMeter(leftLevel: meters.leftLevel, rightLevel: meters.rightLevel)
        } else {
            LEDMeterPair(bands: meters.bands)
        }
    }
}
