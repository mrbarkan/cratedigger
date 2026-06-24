import CrateDiggerCore
import SwiftUI

/// Modal for adding a YouTube stream source. Mirrors the v7 "ADD STREAM SOURCE"
/// modal: a URL field with live source detection and an ADD SOURCE action.
/// Presented from `model.showingAddStreamSheet` (sidebar "+" and radio "ADD URL").
struct AddStreamSheet: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""

    private var parsed: ParsedStream? { StreamURLParser.parse(urlText) }
    private var canAdd: Bool { parsed?.isValidHost == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(theme.orange).frame(width: 7, height: 7)
                Text("ADD STREAM SOURCE")
                    .font(CarbonFont.mono(11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.ink)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PASTE YOUTUBE LINK OR PLAYLIST")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
                TextField("https://youtube.com/@channel  ·  /playlist?list=…  ·  /watch?v=…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(CarbonFont.mono(11))
                    .onSubmit { if canAdd { add() } }
            }

            detectRow

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Source") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var detectRow: some View {
        if let p = parsed {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: detectHueColors(),
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.suggestedTitle)
                        .font(CarbonFont.sans(13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(p.kind.rawValue.uppercased())
                            .font(CarbonFont.mono(7.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(theme.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.cyan.opacity(0.16)))
                        Text(p.host)
                            .font(CarbonFont.mono(9))
                            .foregroundStyle(theme.ink3)
                            .lineLimit(1)
                    }
                    if !p.isValidHost {
                        Text("Only YouTube links are supported")
                            .font(CarbonFont.mono(8.5))
                            .foregroundStyle(theme.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(p.isValidHost ? theme.cyan.opacity(0.05) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(p.isValidHost ? theme.cyan.opacity(0.4) : theme.ink4.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1, dash: p.isValidHost ? [] : [4, 3]))
                    )
            )
        } else {
            HStack {
                Text("Paste a link to detect the source…")
                    .font(CarbonFont.mono(9.5))
                    .tracking(1)
                    .foregroundStyle(theme.ink4)
                Spacer()
            }
            .padding(12)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.ink4.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
    }

    private func detectHueColors() -> [Color] {
        // Stable-ish hue from the host so the preview swatch isn't jarringly random.
        let hue = abs(urlText.hashValue % 360)
        return [
            Color(hue: Double(hue) / 360, saturation: 0.7, brightness: 0.68),
            Color(hue: Double((hue + 40) % 360) / 360, saturation: 0.6, brightness: 0.42)
        ]
    }

    private func add() {
        guard canAdd else { return }
        model.addStream(fromURL: urlText)
        dismiss()
    }
}
