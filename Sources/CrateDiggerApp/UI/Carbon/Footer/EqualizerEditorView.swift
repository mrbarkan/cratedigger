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

    /// The three user slots, mirrored from `PreferencesStore` so the view can
    /// edit them; every mutation writes straight back through `saveSlots`.
    @State private var slots: [CustomEQPreset] = PreferencesStore.shared.customEQPresets
    @State private var renamingSlot: Int?
    @State private var showingImport = false
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            presetGrid
            faderBank
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            footer
        }
        .frame(width: 640, height: 470)
        .background(theme.chassis)
        .sheet(isPresented: $showingImport) {
            AutoEQImportView(slots: $slots).environmentObject(model)
        }
        .alert("Rename Preset",
               isPresented: Binding(get: { renamingSlot != nil },
                                    set: { if !$0 { renamingSlot = nil } })) {
            TextField("Name", text: $draftName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSlot = nil }
        }
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

    // MARK: - Presets
    //
    // Built-ins and user slots share one six-column grid, so the three custom
    // keys are the same size as everything else instead of being a second-class
    // row bolted underneath. Each key carries a lamp: lit means the header EQ
    // key steps through it.

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Self.columns, spacing: 10) {
                ForEach(EQSlot.all) { slot in
                    presetKey(slot)
                }
            }

            HStack(spacing: 6) {
                lamp(lit: true)
                Text("Lit keys cycle from the EQ key in the header. Right-click a user key to save, rename or clear it.")
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(theme.ink4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func presetKey(_ slot: EQSlot) -> some View {
        let isEmptyUser = !model.isEQSlotUsable(slot)
        VStack(spacing: 5) {
            KeyButton(style: keyStyle(slot), action: { press(slot) }) {
                Text(title(for: slot))
            }
            .frame(height: 22)
            // An empty slot reads quieter but stays live: clicking it is how
            // you fill it. `.disabled` would look right and swallow the click.
            .opacity(isEmptyUser ? 0.55 : 1)
            .carbonTip(tip(for: slot))

            Button(action: { model.toggleEQCycle(slot) }) {
                lamp(lit: model.isEQSlotInCycle(slot) && !isEmptyUser)
                    .frame(width: 22, height: 8)          // a forgiving hit area
                    .contentShape(Rectangle())
            }
            .buttonStyle(.carbonHover)
            .disabled(isEmptyUser)
            .carbonTip(isEmptyUser ? "Save a curve here first"
                                   : "Include in the header EQ key's cycle")
        }
        .contextMenu {
            if case .user(let index) = slot {
                Button("Save Current Curve") { store(index) }
                Button("Rename…") {
                    draftName = slots[index].name
                    renamingSlot = index
                }
                Button("Clear", role: .destructive) {
                    slots[index].gains = []
                    saveSlots()
                }
                .disabled(slots[index].isEmpty)
            }
        }
    }

    private func lamp(lit: Bool) -> some View {
        Circle()
            .fill(lit ? theme.orange : theme.ink4.opacity(0.28))
            .frame(width: 5, height: 5)
            .shadow(color: lit ? theme.orange.opacity(0.7) : .clear, radius: 2.5)
    }

    private func title(for slot: EQSlot) -> String {
        switch slot {
        case .preset(let preset): return preset.label
        case .user(let index):    return slots[index].isEmpty ? "+" : slots[index].name
        }
    }

    private func tip(for slot: EQSlot) -> String {
        switch slot {
        case .preset(let preset): return "Load the \(preset.label.capitalized) curve"
        case .user(let index):
            return slots[index].isEmpty ? "Empty slot — click to save the current curve here"
                                        : "Load \(slots[index].name)"
        }
    }

    private func keyStyle(_ slot: EQSlot) -> KeyButtonStyle {
        model.eqSlot == slot && model.eqGains == model.eqCurve(for: slot) ? .selected : .normal
    }

    /// An empty user key stores what's on the faders; everything else loads.
    private func press(_ slot: EQSlot) {
        if case .user(let index) = slot, slots[index].isEmpty {
            store(index)
        } else {
            model.applyEQSlot(slot)
        }
    }

    private func store(_ index: Int) {
        slots[index].gains = model.eqGains
        saveSlots()
        model.eqSlot = .user(index)
    }

    private func commitRename() {
        defer { renamingSlot = nil }
        guard let index = renamingSlot else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        slots[index].name = trimmed.isEmpty ? "USER \(index + 1)" : trimmed.uppercased()
        saveSlots()
    }

    private func saveSlots() {
        PreferencesStore.shared.customEQPresets = slots
        // A cleared slot can't stay in the cycle.
        model.eqCycleIDs = model.eqCycleIDs.filter { EQSlot(id: $0).map(model.isEQSlotUsable) ?? false }
    }

    private var faderBank: some View {
        HStack(alignment: .top, spacing: 10) {
            dBScale
            ForEach(0..<EqualizerProcessor.bandCount, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(gainLabel(model.eqGains[i]))
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
        HStack(spacing: 8) {
            KeyButton(style: .normal, action: {
                model.eqGains = Array(repeating: 0, count: EqualizerProcessor.bandCount)
                model.eqSlot = .preset(.flat)
            }) {
                Text("RESET")
            }
            .frame(width: 90, height: 24)
            .carbonTip("Return every band to 0 dB")

            KeyButton(style: .normal, action: { showingImport = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 9))
                    Text("IMPORT AUTOEQ")
                }
            }
            .frame(width: 170, height: 24)
            .carbonTip("Load a parametric EQ config from squig.link, AutoEQ or oratory1990 onto these faders")

            Spacer()

            KeyButton(style: .glowingFilled, action: { dismiss() }) {
                Text("DONE")
            }
            .frame(width: 90, height: 24)
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    private func gainLabel(_ gain: Double) -> String {
        let dB = Int(gain.rounded())
        return dB == 0 ? "0" : String(format: "%+d", dB)
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
                    .depthShadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
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
