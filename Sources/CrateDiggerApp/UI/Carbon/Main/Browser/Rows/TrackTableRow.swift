import CrateDiggerCore
import SwiftUI

/// One row of the flat Track browser's table.
///
/// The hierarchical layouts keep `TrackRow` — number, title, time — because the
/// panes to their left already say which artist and album you're looking at. The
/// flat list has no such context, so it renders the columns the user chose.
struct TrackTableRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let columns: [TrackColumn]
    let widths: [TrackColumn: Double]
    let selected: Bool
    var dragPayload: String? = nil
    let isPlaying: Bool
    var isOffline: Bool = false
    var isMissing: Bool = false
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: TrackTableMetrics.columnSpacing) {
                ForEach(columns) { column in
                    cell(column)
                }
            }
            .padding(.horizontal, TrackTableMetrics.horizontalPadding)
            .padding(.vertical, 4)
            .background(selectedBackground)
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.05))
                    .frame(height: 1),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate() })
        // Dim tracks that aren't playable right now — offline drive or missing file.
        .opacity((isOffline || isMissing) && !selected ? 0.55 : 1)
        .draggable(dragPayload ?? "track::" + loaded.track.id.uuidString)
    }

    @ViewBuilder
    private func cell(_ column: TrackColumn) -> some View {
        let isTitle = column == .title
        HStack(spacing: 4) {
            // The status glyphs ride in the title cell — they qualify the track,
            // not any one field.
            if isTitle, isOffline || isMissing {
                Image(systemName: isMissing ? "questionmark.folder" : "externaldrive.badge.xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.orange)
                    .help(isMissing ? "File is missing — locate it in Library Maintenance"
                                    : "On a disconnected drive")
            }
            Text(column.value(for: loaded))
                .font(isTitle
                      ? CarbonFont.sans(12.5, weight: isPlaying ? .semibold : .medium)
                      : CarbonFont.mono(10))
                .foregroundStyle(isTitle ? titleColor : metaColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: isTitle ? .infinity : nil,
               alignment: column.isTrailingAligned ? .trailing : .leading)
        .frame(width: isTitle ? nil : widths[column] ?? column.defaultWidth,
               alignment: column.isTrailingAligned ? .trailing : .leading)
    }

    @ViewBuilder
    private var selectedBackground: some View {
        if selected {
            CarbonSelectionSlot(cornerRadius: 0)
        } else {
            Color.clear
        }
    }

    private var titleColor: Color {
        if selected { return theme.slotInk }
        return isPlaying ? theme.orange : theme.ink
    }

    private var metaColor: Color {
        selected ? theme.slotInk.opacity(0.75) : theme.ink3
    }
}

/// Shared metrics so the header's cells land exactly over the rows'.
enum TrackTableMetrics {
    static let columnSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 10
}
