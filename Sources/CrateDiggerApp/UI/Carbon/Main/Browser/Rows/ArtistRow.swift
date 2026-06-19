import CrateDiggerCore
import SwiftUI

struct ArtistRow: View {
    @Environment(\.carbon) private var theme
    let artist: Artist
    let selected: Bool
    let isPlayingHere: Bool
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        ColumnRow(
            selected: selected,
            isPlaying: isPlayingHere,
            onSelect: onSelect,
            onActivate: onPrimaryAction
        ) {
            Text(isPlayingHere ? "▸" : "·")
                .font(CarbonFont.mono(9.5, weight: .medium))
                .foregroundStyle(leadColor)
        } title: {
            Text(artist.name)
                .font(CarbonFont.sans(12.5, weight: .medium))
                .foregroundStyle(titleColor)
        } trail: {
            Text("\(artist.albumCount)")
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(metaColor)
        }
    }

    private var leadColor: Color {
        if selected { return theme.selectionInk }
        if isPlayingHere { return theme.orange }
        return theme.ink3
    }

    private var titleColor: Color {
        selected ? theme.selectionInk : theme.ink
    }

    private var metaColor: Color {
        selected ? selectedMetaColor : theme.ink3
    }

    private var selectedMetaColor: Color {
        theme.selectionInk.opacity(0.72)
    }
}
