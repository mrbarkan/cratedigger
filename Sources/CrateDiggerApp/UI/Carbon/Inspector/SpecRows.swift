import CrateDiggerCore
import SwiftUI

/// What the inspector's one user-chosen spec row shows. The fixed rows above
/// it (year / format / tracks) are the same for everyone; this slot is where
/// the fact *you* care about lives.
enum SpecField: String, CaseIterable, Identifiable {
    case genre, bitrate, sample, added, plays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .genre:   return "Genre"
        case .bitrate: return "Bitrate"
        case .sample:  return "Sample"
        case .added:   return "Added"
        case .plays:   return "Plays"
        }
    }
}

struct SpecRows: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album?

    @AppStorage("cratedigger.inspector.customSpec") private var customFieldRaw = SpecField.genre.rawValue
    @State private var hoveringCustom = false

    private var customField: SpecField { SpecField(rawValue: customFieldRaw) ?? .genre }

    private static let keyWidth: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fixedRows, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    keyLabel(key, tint: theme.ink3)
                    valueLabel(value)
                }
            }
            customRow
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

    private func keyLabel(_ key: String, tint: Color) -> some View {
        Text(key.uppercased())
            .font(CarbonFont.mono(9, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(tint)
            .frame(width: Self.keyWidth, alignment: .leading)
    }

    private func valueLabel(_ value: String) -> some View {
        Text(value)
            .font(CarbonFont.mono(11, weight: .medium))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
    }

    /// The pickable row: hovering tints its key and shows the picker glyph, so
    /// it reads as a control rather than another printed fact.
    private var customRow: some View {
        Menu {
            ForEach(SpecField.allCases) { field in
                Button {
                    customFieldRaw = field.rawValue
                } label: {
                    if field == customField {
                        Label(field.title, systemImage: "checkmark")
                    } else {
                        Text(field.title)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                keyLabel(customField.title, tint: hoveringCustom ? theme.orange : theme.ink3)
                valueLabel(customValue)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.ink4)
                    .opacity(hoveringCustom ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.ink.opacity(hoveringCustom ? 0.07 : 0))
                .padding(.horizontal, -5)
                .padding(.vertical, -3)
        )
        .onHover { hoveringCustom = $0 }
        .animation(.easeInOut(duration: 0.12), value: hoveringCustom)
        .carbonTip("Click to choose what this row shows")
    }

    // MARK: - Values

    private var fixedRows: [(String, String)] {
        guard let album else {
            return [("Year", "—"), ("Format", "—"), ("Tracks", "—")]
        }
        let formatLabel = album.formats.sorted().joined(separator: " · ").uppercased()
        return [
            ("Year",   album.year.map(String.init) ?? "—"),
            ("Format", formatLabel.isEmpty ? "—" : formatLabel),
            ("Tracks", "\(album.trackCount) · \(formatDuration(album.totalDurationSeconds))")
        ]
    }

    private var customValue: String {
        guard let album else { return "—" }
        switch customField {
        case .genre:   return genre(for: album)
        case .bitrate: return bitrate(for: album)
        case .sample:  return sampleRate(for: album)
        case .added:   return dateAdded(for: album)
        case .plays:   return plays(for: album)
        }
    }

    private func genre(for album: Album) -> String {
        let names = Set(album.tracks.compactMap(\.metadata.genre).filter { !$0.isEmpty })
        return names.isEmpty ? "—" : names.sorted().joined(separator: " · ")
    }

    private func bitrate(for album: Album) -> String {
        let bitrates = album.tracks.compactMap(\.track.bitrateKbps)
        guard let lo = bitrates.min(), let hi = bitrates.max() else { return "—" }
        return lo == hi ? "\(lo) kbps" : "\(lo)–\(hi) kbps"
    }

    private func sampleRate(for album: Album) -> String {
        let rates = Set(album.tracks.compactMap(\.track.sampleRateHz))
        guard !rates.isEmpty else { return "—" }
        return rates.sorted().map { String(format: "%.1f kHz", Double($0) / 1000) }.joined(separator: " · ")
    }

    /// Listening stats are path-keyed in `ListeningStore`, never on the track.
    private func statsForAlbum(_ album: Album) -> [ListeningStats] {
        guard let store = model.listeningStore else { return [] }
        return album.tracks.compactMap { store.stats(path: $0.track.fileURL.path) }
    }

    private func dateAdded(for album: Album) -> String {
        guard let earliest = statsForAlbum(album).map(\.dateAdded).min() else { return "—" }
        return earliest.formatted(date: .abbreviated, time: .omitted)
    }

    private func plays(for album: Album) -> String {
        let stats = statsForAlbum(album)
        guard !stats.isEmpty else { return "—" }
        return String(stats.reduce(0) { $0 + $1.playCount })
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return seconds.asClockHMS
    }
}
