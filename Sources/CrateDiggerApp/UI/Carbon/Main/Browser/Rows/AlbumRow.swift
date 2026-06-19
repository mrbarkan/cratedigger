import CrateDiggerCore
import SwiftUI

struct AlbumRow: View {
    @Environment(\.carbon) private var theme
    let album: Album
    let selected: Bool
    let isPlayingHere: Bool
    let onSelect: () -> Void

    var body: some View {
        ColumnRow(
            selected: selected,
            isPlaying: isPlayingHere,
            onSelect: onSelect,
            onActivate: nil
        ) {
            Text(isPlayingHere ? "▸" : "·")
                .font(CarbonFont.mono(9.5, weight: .medium))
                .foregroundStyle(leadColor)
        } title: {
            Text(album.title)
                .font(CarbonFont.sans(12.5, weight: .medium))
                .foregroundStyle(titleColor)
        } trail: {
            Text(yearLabel)
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(metaColor)
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
