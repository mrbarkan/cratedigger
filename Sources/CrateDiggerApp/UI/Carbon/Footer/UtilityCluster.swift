import AppKit
import CrateDiggerCore
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

    private var grid: some View {
        HStack(spacing: 8) {
            // Tag shortcuts to the Now-Playing OLED view but its visual state
            // doesn't mirror oledView — that's what the DisplayModeButton is
            // for. Keeping it as a momentary trigger.
            key(label: "Tag", on: false) {
                model.oledView = .nowPlaying
            }
            // Cnvrt jumps straight to the patch-bay (OLED + Inspector both
            // switch to convert mode). Lights up while a batch is running.
            key(label: "Cnvrt", on: model.conversionProgress.isRunning) {
                model.oledView = .conversion
                if model.inspectorCollapsed {
                    model.inspectorCollapsed = false
                }
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
