import SwiftUI
import CrateDiggerCore

/// A row in a value column: the value and how many tracks sit under it. The
/// same slot, type and lead mark as an artist row, so a Genre column reads as
/// the same hardware with a different label printed on it.
struct FacetRow: View {
    @Environment(\.carbon) private var theme
    let value: FacetValue
    let selected: Bool
    var dragPayload: String? = nil
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        ColumnRow(
            selected: selected,
            onSelect: onSelect,
            onActivate: onActivate
        ) {
            RowLeadMark(isPlaying: false, selected: selected)
        } title: {
            Text(value.title)
                .font(CarbonFont.sans(12.5, weight: .medium))
                .foregroundStyle(theme.rowTitleColor(selected: selected))
        } trail: {
            Text("\(value.count)")
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(theme.rowMetaColor(selected: selected))
        }
        .draggable(dragPayload ?? value.id)
    }
}
