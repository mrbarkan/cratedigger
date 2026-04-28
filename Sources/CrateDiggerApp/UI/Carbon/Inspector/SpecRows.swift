import CrateDiggerCore
import SwiftUI

struct SpecRows: View {
    @Environment(\.carbon) private var theme
    let album: Album?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(key.uppercased())
                        .font(CarbonFont.mono(9, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(theme.ink3)
                        .frame(width: 78, alignment: .leading)
                    Text(value)
                        .font(CarbonFont.mono(11, weight: .medium))
                        .foregroundStyle(theme.ink)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var rows: [(String, String)] {
        guard let album else {
            return [("Genre", "—"), ("Format", "—"), ("Tracks", "—")]
        }
        let formatLabel = album.formats.sorted().joined(separator: " · ").uppercased()
        let trackTotal = formatDuration(album.totalDurationSeconds)
        let bitrateRange = bitrateLabel(for: album)
        let sampleRateLabel = sampleRate(for: album)
        let yearLabel = album.year.map(String.init) ?? "—"

        return [
            ("Album",  album.title.isEmpty ? "—" : album.title),
            ("Artist", album.artistName.isEmpty ? "—" : album.artistName),
            ("Year",   yearLabel),
            ("Format", formatLabel.isEmpty ? "—" : formatLabel),
            ("Bitrate", bitrateRange),
            ("Sample", sampleRateLabel),
            ("Tracks",  "\(album.trackCount) · \(trackTotal)")
        ]
    }

    private func bitrateLabel(for album: Album) -> String {
        let bitrates = album.tracks.compactMap(\.track.bitrateKbps)
        guard !bitrates.isEmpty else { return "—" }
        let lo = bitrates.min() ?? 0
        let hi = bitrates.max() ?? 0
        if lo == hi { return "\(lo) kbps" }
        return "\(lo)–\(hi) kbps"
    }

    private func sampleRate(for album: Album) -> String {
        let rates = Set(album.tracks.compactMap(\.track.sampleRateHz))
        guard !rates.isEmpty else { return "—" }
        return rates.sorted().map { String(format: "%.1f kHz", Double($0) / 1000) }.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
