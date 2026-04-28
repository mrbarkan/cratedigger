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
        if selected { return theme.isDark ? Color(hex: 0x1A1209) : theme.cyan }
        if isPlayingHere { return theme.orange }
        return theme.ink3
    }

    private var titleColor: Color {
        selected ? selectedTextColor : theme.ink
    }

    private var metaColor: Color {
        selected ? selectedMetaColor : theme.ink3
    }

    private var selectedTextColor: Color {
        theme.isDark ? Color(hex: 0x1A1209) : Color(hex: 0xF3F6EC)
    }

    private var selectedMetaColor: Color {
        theme.isDark ? Color(hex: 0x1A1209).opacity(0.7) : theme.chassisLo
    }
}
