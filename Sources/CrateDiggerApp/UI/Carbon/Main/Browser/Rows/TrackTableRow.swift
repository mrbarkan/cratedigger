import CrateDiggerCore
import AppKit
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
    /// Playlist position, shown in place of the track-number tag when the table
    /// is listing a playlist in its own order.
    var positionNumber: Int? = nil
    /// Set only while a playlist is in its own order: accepts a dropped
    /// selection and moves it in ahead of this row.
    var onReorderDrop: (([String]) -> Void)? = nil
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        // Activation reads the click count off the event rather than riding a
        // `TapGesture(count: 2)`. This row is both a drag source and — in a
        // playlist, the only place the reorder target is live — a drop
        // destination, and those swallow the second mouse-down, so the gesture
        // never completed and double-clicking a playlist track did nothing at
        // all. The event always knows.
        Button(action: {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onActivate() } else { onSelect() }
        }) {
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
        // Dim tracks that aren't playable right now — offline drive or missing file.
        .opacity((isOffline || isMissing) && !selected ? 0.55 : 1)
        .draggable(dragPayload ?? "track::" + loaded.track.id.uuidString)
        .modifier(ReorderDropTarget(onDrop: onReorderDrop))
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
            Text(cellText(column))
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

    /// Playlist position wins over the track-number tag: in a playlist "3" means
    /// third in the list, not track 3 of its album.
    private func cellText(_ column: TrackColumn) -> String {
        if column == .trackNumber, let positionNumber { return String(positionNumber) }
        return column.value(for: loaded)
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

/// The insertion affordance for playlist reordering: a lit rule along the row's
/// top edge while a drag hovers, so you can see where the drop will land.
private struct ReorderDropTarget: ViewModifier {
    @Environment(\.carbon) private var theme
    let onDrop: (([String]) -> Void)?
    @State private var targeted = false

    func body(content: Content) -> some View {
        if let onDrop {
            content
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.orange)
                        .frame(height: 2)
                        .opacity(targeted ? 1 : 0)
                }
                .dropDestination(for: String.self) { items, _ in
                    onDrop(items)
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}
