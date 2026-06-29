import CrateDiggerCore
import SwiftUI

/// Industry-standard graphic EQ: a bank of vertical faders (one per band) with a
/// dB scale and quick presets. Opened by clicking the footer EQ panel. Edits
/// `model.eqGains` live, so playback updates as you drag.
struct EqualizerEditorView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private let range: ClosedRange<Double> = -12...12

    var body: some View {
        VStack(spacing: 0) {
            header
            presets
            faderBank
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            footer
        }
        .frame(width: 600, height: 380)
        .background(theme.chassis)
    }

    private var header: some View {
        HStack {
            Text("Equalizer".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
            Toggle("ON", isOn: $model.eqEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(theme.orange)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(EQPreset.allCases) { preset in
                Button(preset.label) {
                    model.eqPreset = preset
                    model.eqGains = preset.gainCurve()
                    model.eqEnabled = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(model.eqPreset == preset ? theme.orange : nil)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var faderBank: some View {
        HStack(alignment: .top, spacing: 10) {
            dBScale
            ForEach(0..<EqualizerProcessor.bandCount, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", model.eqGains[i]))
                        .font(CarbonFont.mono(8, weight: .bold))
                        .foregroundStyle(model.eqEnabled ? theme.orange : theme.ink4)
                        .frame(height: 12)
                    EQFader(gain: $model.eqGains[i], range: range, enabled: model.eqEnabled)
                        .frame(maxWidth: .infinity)
                    Text(freqLabel(i))
                        .font(CarbonFont.mono(7.5, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(height: 12)
                }
            }
        }
        .opacity(model.eqEnabled ? 1 : 0.5)
    }

    // +12 / 0 / -12 reference scale aligned to the fader travel.
    private var dBScale: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)                 // align with dB readout row
            VStack {
                Text("+12").font(CarbonFont.mono(7)).foregroundStyle(theme.ink4)
                Spacer()
                Text("0").font(CarbonFont.mono(7, weight: .bold)).foregroundStyle(theme.ink3)
                Spacer()
                Text("-12").font(CarbonFont.mono(7)).foregroundStyle(theme.ink4)
            }
            Spacer().frame(height: 12 + 6)             // align with freq-label row
        }
        .frame(width: 26)
    }

    private var footer: some View {
        HStack {
            Button("Reset to Flat") {
                model.eqGains = Array(repeating: 0, count: EqualizerProcessor.bandCount)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(theme.orange)
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    private func freqLabel(_ i: Int) -> String {
        let f = EqualizerProcessor.centerFrequencies[i]
        return f >= 1000 ? String(format: "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

/// A single vertical fader. Drag the handle to set the gain; the center line is
/// 0 dB. Mirrors a hardware graphic-EQ slider.
private struct EQFader: View {
    @Environment(\.carbon) private var theme
    @Binding var gain: Double
    let range: ClosedRange<Double>
    var enabled: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let frac = (gain - range.lowerBound) / span          // 0 bottom … 1 top
            let handleY = h * (1 - frac)

            ZStack {
                // Recessed track.
                Capsule()
                    .fill(theme.wellDeep.opacity(theme.isDark ? 0.8 : 0.35))
                    .frame(width: 5)
                    .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1).frame(width: 5))

                // 0 dB centre line.
                Rectangle()
                    .fill(theme.ink4.opacity(0.4))
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: h / 2)

                // Lit fill from centre to the handle.
                Capsule()
                    .fill((enabled ? theme.orange : theme.ink3).opacity(0.85))
                    .frame(width: 5, height: max(0, abs(handleY - h / 2)))
                    .position(x: geo.size.width / 2, y: (handleY + h / 2) / 2)

                // Handle.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(colors: [theme.metalHi, theme.metal, theme.metalLo],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .overlay(Rectangle().fill((enabled ? theme.orange : theme.ink4).opacity(0.9)).frame(height: 1.5))
                    .frame(width: 24, height: 12)
                    .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
                    .position(x: geo.size.width / 2, y: handleY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard enabled else { return }
                    let f = 1 - min(max(value.location.y / h, 0), 1)
                    let raw = range.lowerBound + f * span
                    gain = (raw * 2).rounded() / 2          // snap to 0.5 dB
                }
            )
        }
        .frame(width: 28)
    }
}
