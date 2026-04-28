import SwiftUI

struct UtilityCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @StateObject private var meters = MeterSimulator()

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            grid
            LEDMeterPair(leftLevel: meters.leftLevel, rightLevel: meters.rightLevel)
            VolumeKnob(value: $model.playbackVolume)
        }
        .onAppear { syncMeterRunning() }
        .onChange(of: model.playbackState) { _ in
            syncMeterRunning()
        }
    }

    private var grid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                key(label: "Mono", disabled: true) {}  // TODO: mono fold-down playback
                key(label: "Loop", disabled: true) {}  // TODO: track-level repeat-one (separate from album repeat)
            }
            HStack(spacing: 8) {
                key(label: "Tag", on: model.oledView == .nowPlaying) {
                    model.oledView = .nowPlaying
                }
                key(label: "Eject", disabled: true) {} // TODO: hand-off to AirPlay / external device
            }
        }
    }

    private func key(label: String, on: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let style: KeyButtonStyle = disabled ? .disabled : (on ? .selected : .normal)
        return KeyButton(style: style, action: action) {
            Text(label.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.6)
        }
        .frame(width: 70, height: CarbonLayout.keyHeight)
    }

    private func syncMeterRunning() {
        if model.playbackState == .playing {
            meters.start()
        } else {
            meters.stop()
        }
    }
}
