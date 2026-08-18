import SwiftUI

/// The bullet at the head of an artist / album row.
///
/// Three states share one slot, in priority order: playing beats queued beats
/// idle. They share it deliberately — a queued-for-device dot next to the bullet
/// read as two marks meaning two different things, when it is one row status.
struct RowLeadMark: View {
    @Environment(\.carbon) private var theme
    let isPlaying: Bool
    var pendingSync: Bool = false
    let selected: Bool

    static let tip = "Queued for a device — waiting for the next SYNC"

    var body: some View {
        if pendingSync && !isPlaying {
            Circle()
                .fill(selected ? theme.selectionInk : theme.orange)
                .frame(width: 6, height: 6)
                .carbonTip(Self.tip)
        } else {
            Text(isPlaying ? "▸" : "·")
                .font(CarbonFont.mono(9.5, weight: .medium))
                .foregroundStyle(theme.rowLeadColor(selected: selected, isPlaying: isPlaying))
        }
    }
}
