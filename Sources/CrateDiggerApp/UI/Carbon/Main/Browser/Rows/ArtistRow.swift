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
            onSelect: onSelect,
            onActivate: onPrimaryAction
        ) {
            Text(isPlayingHere ? "▸" : "·")
                .font(CarbonFont.mono(9.5, weight: .medium))
                .foregroundStyle(theme.rowLeadColor(selected: selected, isPlaying: isPlayingHere))
        } title: {
            Text(artist.name)
                .font(CarbonFont.sans(12.5, weight: .medium))
                .foregroundStyle(theme.rowTitleColor(selected: selected))
        } trail: {
            Text("\(artist.albumCount)")
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(theme.rowMetaColor(selected: selected))
        }
        .draggable("artist::" + artist.id)
    }
}
