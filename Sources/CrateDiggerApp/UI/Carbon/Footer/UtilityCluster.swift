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
            key(label: "Tag", on: model.oledView == .nowPlaying) {
                model.oledView = .nowPlaying
            }
            key(label: "Cnvrt", on: model.oledView == .conversion) {
                presentConversionOptions()
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

    private func presentConversionOptions() {
        model.oledView = .conversion

        guard let host = NSApp.keyWindow?.contentViewController else { return }

        let controller = ConversionOptionsSheetController(
            initialSelection: model.makeInitialConversionSelection(),
            outputFormats: OutputFormat.allCases,
            bitrateOptions: [128, 160, 192, 256, 320],
            sampleRateOptions: [44_100, 48_000, 88_200, 96_000]
        )
        controller.onDecision = { [weak controller, weak model = model] selection in
            controller?.dismiss(nil)
            guard let selection, let model else { return }
            // Re-resolve the host after dismissal so the sheet stack is settled.
            guard let host = NSApp.keyWindow?.contentViewController else { return }
            model.runConversion(selection: selection, presentingFrom: host)
        }
        host.presentAsSheet(controller)
    }
}
