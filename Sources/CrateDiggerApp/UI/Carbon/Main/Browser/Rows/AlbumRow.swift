import CrateDiggerCore
import SwiftUI

struct AlbumRow: View {
    @Environment(\.carbon) private var theme
    let album: Album
    let selected: Bool
    /// Built by the view model so a drag inside a multi-selection carries all of it.
    var dragPayload: String? = nil
    let isPlayingHere: Bool
    /// Something under this album is queued for a device — see DeviceQueueBar.
    var pendingSync: Bool = false
    let onSelect: () -> Void

    // Optional params for version-group rows (nil = plain album row).
    var badge: String? = nil
    var disclosed: Bool? = nil
    var onDisclose: (() -> Void)? = nil

    var body: some View {
        ColumnRow(
            selected: selected,
            onSelect: onSelect,
            onActivate: nil
        ) {
            if let onDisclose, let disclosed {
                // Disclosure chevron replaces the bullet for release rows.
                // A grouped release needs its chevron, so the queue shows as a
                // tint on it rather than displacing the only way to open the row.
                Button(action: onDisclose) {
                    Image(systemName: disclosed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pendingSync && !selected
                                         ? theme.orange
                                         : (selected ? theme.selectionInk : theme.ink3))
                        .frame(width: 16, alignment: .center)
                }
                .buttonStyle(.carbonHover)
                .frame(width: 16, alignment: .center)
                .carbonTip(pendingSync ? RowLeadMark.tip : "")
            } else {
                RowLeadMark(isPlaying: isPlayingHere, pendingSync: pendingSync, selected: selected)
            }
        } title: {
            HStack(spacing: 5) {
                // Only shown once the medium has been tagged — untagged albums
                // keep the plain title, no placeholder icon.
                if let media = album.mediaFormat {
                    Image(systemName: media.symbolName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(selected ? theme.selectionInk.opacity(0.8) : theme.ink3)
                        .help(media.rawValue)
                }
                Text(album.title)
                    .font(CarbonFont.sans(12.5, weight: .medium))
                    .foregroundStyle(theme.rowTitleColor(selected: selected))
            }
        } trail: {
            if let badge {
                Text(badge)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .foregroundStyle(selected ? theme.selectionInk.opacity(0.85) : theme.ink3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selected ? theme.selectionInk.opacity(0.18) : theme.ink.opacity(0.08))
                    )
            } else {
                Text(yearLabel)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.rowMetaColor(selected: selected))
            }
        }
        .draggable(dragPayload ?? "album::" + album.id)
    }

    private var yearLabel: String {
        guard let year = album.year else { return "—" }
        return "'" + String(format: "%02d", year % 100)
    }
}
