import AppKit
import CrateDiggerCore
import SwiftUI
import UniformTypeIdentifiers

/// Paste (or drop) an AutoEQ parametric config and land it on the 12 faders.
/// The preview is the honest part: it draws the parametric curve the file asks
/// for *and* what these twelve bands can actually do, so you can see the fit
/// before you commit to it.
struct AutoEQImportView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @Binding var slots: [CustomEQPreset]

    @State private var text = ""
    @State private var name = ""
    /// nil = apply to the faders only, don't occupy a user slot.
    @State private var targetSlot: Int?

    private var profile: AutoEQProfile { AutoEQParser.parse(text) }
    private var result: AutoEQMapper.Result { AutoEQMapper.map(profile) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 14) {
                source
                preview
            }
            .padding(14)
            footer
        }
        .frame(width: 680, height: 460)
        .background(theme.chassis)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Import AutoEQ".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Text("Parametric EQ from squig.link, AutoEQ, oratory1990, Wavelet or Poweramp.")
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Paste area

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.hair, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if text.isEmpty {
                    Text("""
                    Preamp: -6.1 dB
                    Filter 1: ON PK Fc 105 Hz Gain -2.5 dB Q 0.8
                    Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.7
                    …
                    """)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.ink4.opacity(0.6))
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
            // A downloaded AutoEQ .txt can just be dragged in.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFile(providers)
            }

            HStack(spacing: 8) {
                Button("Open File…") { openFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Paste") { pasteFromClipboard() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .frame(width: 300)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutoEQCurveView(target: profile.isEmpty ? [] : AutoEQMapper.curve(profile, at: Self.grid),
                            fitted: profile.isEmpty ? [] : AutoEQMapper.curve(forGains: result.gains, at: Self.grid))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                legendDot(theme.ink3, "Source")
                legendDot(theme.orange, "12 bands")
                Spacer()
            }

            Text(status)
                .font(CarbonFont.mono(9))
                .foregroundStyle(statusTint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(label.uppercased())
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink3)
        }
    }

    private static let grid = AutoEQMapper.logGrid(from: 20, to: 20_000, count: 220)

    private var status: String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Paste a parametric config to see how it maps."
        }
        guard !profile.isEmpty else {
            return "No filters found. This wants AutoEQ parametric text, not a frequency-response export."
        }
        var parts = ["\(profile.filters.count) filter\(profile.filters.count == 1 ? "" : "s")"]
        if profile.preampDB != 0 {
            parts.append(String(format: "preamp %.1f dB ignored", profile.preampDB))
        }
        parts.append(String(format: "fit ±%.1f dB", result.fitErrorDB))
        if result.clampedBands > 0 {
            parts.append("\(result.clampedBands) band\(result.clampedBands == 1 ? "" : "s") clipped at ±12")
        }
        if profile.unsupportedCount > 0 {
            parts.append("\(profile.unsupportedCount) unsupported skipped")
        }
        return parts.joined(separator: " · ")
    }

    private var statusTint: Color {
        if text.isEmpty { return theme.ink4 }
        return profile.isEmpty ? theme.orange : theme.ink3
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)

            Picker("", selection: $targetSlot) {
                Text("Faders only").tag(Int?.none)
                ForEach(0..<CustomEQPreset.slotCount, id: \.self) { index in
                    Text("Save to \(slots[index].name)").tag(Int?.some(index))
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .tint(theme.orange)
                .disabled(profile.isEmpty)
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    // MARK: - Actions

    private func apply() {
        let gains = result.gains
        model.eqGains = gains
        model.eqEnabled = true

        if let slot = targetSlot {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            slots[slot] = CustomEQPreset(
                name: trimmed.isEmpty ? "USER \(slot + 1)" : trimmed.uppercased(),
                gains: gains
            )
            PreferencesStore.shared.customEQPresets = slots
        }
        dismiss()
    }

    private func pasteFromClipboard() {
        if let pasted = NSPasteboard.general.string(forType: .string) { text = pasted }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func loadDroppedFile(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in load(url) }
        }
        return true
    }

    private func load(_ url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents
        // AutoEQ names the file after the headphone; that's the best name we get.
        if name.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ParametricEQ", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        }
        if targetSlot == nil { targetSlot = firstEmptySlot }
    }

    private var firstEmptySlot: Int? {
        slots.firstIndex(where: \.isEmpty)
    }
}

/// The two curves over a log frequency axis, ±12 dB. Same shape the faders
/// will produce, drawn from the same biquad math the audio path uses.
private struct AutoEQCurveView: View {
    @Environment(\.carbon) private var theme
    let target: [Double]
    let fitted: [Double]

    private let range: Double = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.hair, lineWidth: 1))

                // ±6 dB guides plus the 0 dB centre.
                ForEach([-6.0, 0.0, 6.0], id: \.self) { dB in
                    let y = h / 2 - (dB / range) * (h / 2)
                    Path { $0.move(to: CGPoint(x: 6, y: y)); $0.addLine(to: CGPoint(x: w - 6, y: y)) }
                        .stroke(theme.ink4.opacity(dB == 0 ? 0.45 : 0.18),
                                style: .init(lineWidth: 1, dash: dB == 0 ? [] : [2, 3]))
                }

                curve(target, in: geo.size)
                    .stroke(theme.ink3.opacity(0.8), style: .init(lineWidth: 1.5, lineJoin: .round))
                curve(fitted, in: geo.size)
                    .stroke(theme.orange, style: .init(lineWidth: 2, lineJoin: .round))
            }
        }
    }

    private func curve(_ values: [Double], in size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let inset: CGFloat = 6
            let usable = size.width - inset * 2
            for (index, value) in values.enumerated() {
                let x = inset + usable * CGFloat(index) / CGFloat(values.count - 1)
                let clamped = min(max(value, -range), range)
                let y = size.height / 2 - CGFloat(clamped / range) * (size.height / 2 - inset)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
        }
    }
}
