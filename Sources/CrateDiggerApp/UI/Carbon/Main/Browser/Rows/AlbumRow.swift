import CrateDiggerCore
import SwiftUI

struct AlbumRow: View {
    @Environment(\.carbon) private var theme
    let album: Album
    let selected: Bool
    let isPlayingHere: Bool
    let onSelect: () -> Void

    // Optional params for version-group rows (nil = plain album row).
    var badge: String? = nil
    var disclosed: Bool? = nil
    var onDisclose: (() -> Void)? = nil

    var body: some View {
        ColumnRow(
            selected: selected,
            isPlaying: isPlayingHere,
            onSelect: onSelect,
            onActivate: nil
        ) {
            if let onDisclose, let disclosed {
                // Disclosure chevron replaces the bullet for release rows.
                Button(action: onDisclose) {
                    Image(systemName: disclosed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? theme.selectionInk : theme.ink3)
                        .frame(width: 16, alignment: .center)
                }
                .buttonStyle(.plain)
                .frame(width: 16, alignment: .center)
            } else {
                Text(isPlayingHere ? "▸" : "·")
                    .font(CarbonFont.mono(9.5, weight: .medium))
                    .foregroundStyle(leadColor)
            }
        } title: {
            Text(album.title)
                .font(CarbonFont.sans(12.5, weight: .medium))
                .foregroundStyle(titleColor)
        } trail: {
            if let badge {
                HStack(spacing: 4) {
                    Text(badge)
                        .font(CarbonFont.mono(8.5, weight: .semibold))
                        .foregroundStyle(selected ? theme.selectionInk.opacity(0.85) : theme.ink3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? theme.selectionInk.opacity(0.18) : theme.ink.opacity(0.08))
                        )
                }
            } else {
                Text(yearLabel)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(metaColor)
            }
        }
        .draggable("album::" + album.id)
    }

    private var yearLabel: String {
        guard let year = album.year else { return "—" }
        return "'" + String(format: "%02d", year % 100)
    }

    private var leadColor: Color {
        if selected { return theme.selectionInk }
        if isPlayingHere { return theme.orange }
        return theme.ink3
    }

    private var titleColor: Color { selected ? theme.selectionInk : theme.ink }
    private var metaColor: Color  { selected ? selectedMetaColor : theme.ink3 }

    private var selectedMetaColor: Color {
        theme.selectionInk.opacity(0.72)
    }
}
