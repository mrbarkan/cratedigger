import CrateDiggerCore
import SwiftUI

/// The flat Track browser's column header.
///
/// Click a sortable header to sort by it; click again to reverse — the arrow
/// says which way. Right-click anywhere on the bar to choose which columns are
/// shown. Columns the browser can't sort on (genre, format, …) are still
/// clickable targets for nothing, so they don't get the pointer treatment.
struct TrackTableHeader: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    let columns: [TrackColumn]
    let widths: [TrackColumn: Double]

    var body: some View {
        HStack(spacing: TrackTableMetrics.columnSpacing) {
            ForEach(columns) { column in
                header(column)
            }
        }
        .padding(.horizontal, TrackTableMetrics.horizontalPadding)
        .padding(.vertical, 5)
        .background(theme.chassisHi.opacity(0.35))
        .overlay(
            Rectangle().fill(Color.black.opacity(0.10)).frame(height: 1),
            alignment: .bottom
        )
        .contextMenu { columnMenu }
    }

    /// In a playlist the leading column is the playlist's own order, so its
    /// header is the way back to it rather than a sort by the track-number tag.
    private var showsPlaylistOrderColumn: Bool { model.isPlaylistSource }

    @ViewBuilder
    private func header(_ column: TrackColumn) -> some View {
        let isTitle = column == .title
        let isPlaylistOrder = showsPlaylistOrderColumn && column == .trackNumber
        let isSorted = isPlaylistOrder
            ? !model.playlistSorted
            : (column.sortField != nil && model.trackSortField == column.sortField && !(showsPlaylistOrderColumn && !model.playlistSorted))

        Group {
            if isPlaylistOrder {
                Button { model.playlistSorted = false } label: {
                    label(column, isSorted: isSorted, showsDirection: false)
                }
                .buttonStyle(.carbonHover)
                .carbonTip("Back to the playlist's own order — drag rows to rearrange it")
            } else if let field = column.sortField {
                Button {
                    if model.trackSortField == field, !(showsPlaylistOrderColumn && !model.playlistSorted) {
                        model.trackSortAscending.toggle()
                    } else {
                        model.trackSortField = field
                        model.trackSortAscending = true
                    }
                    // Sorting a playlist is a view of it, not a change to it —
                    // reordering switches off until you come back to # order.
                    if showsPlaylistOrderColumn { model.playlistSorted = true }
                } label: {
                    label(column, isSorted: isSorted)
                }
                .buttonStyle(.carbonHover)
            } else {
                label(column, isSorted: false)
            }
        }
        .frame(maxWidth: isTitle ? .infinity : nil,
               alignment: column.isTrailingAligned ? .trailing : .leading)
        .frame(width: isTitle ? nil : widths[column] ?? column.defaultWidth,
               alignment: column.isTrailingAligned ? .trailing : .leading)
    }

    private func label(_ column: TrackColumn, isSorted: Bool, showsDirection: Bool = true) -> some View {
        HStack(spacing: 3) {
            if column.isTrailingAligned { Spacer(minLength: 0) }
            Text(column.title.uppercased())
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(isSorted ? theme.orange : theme.ink3)
                .lineLimit(1)
            if isSorted, showsDirection {
                Image(systemName: model.trackSortAscending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(theme.orange)
            }
            if !column.isTrailingAligned { Spacer(minLength: 0) }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var columnMenu: some View {
        ForEach(TrackColumn.allCases) { column in
            Button {
                model.toggleTrackColumn(column)
            } label: {
                // A checkmark prefix rather than Toggle: this menu is rebuilt on
                // every open, and Toggle's binding would need one per column.
                Text((model.trackColumns.contains(column) ? "✓ " : "   ") + column.title)
            }
            .disabled(column == TrackColumn.required)
        }
        Divider()
        Button("Reset Columns") { model.trackColumns = TrackColumn.defaultSelection }
    }
}
