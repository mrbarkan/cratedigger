import CrateDiggerCore
import SwiftUI

/// Old value → new value, with only the part that actually differs carrying
/// any emphasis. Without it a one-letter casing fix and a wholesale retitle
/// looked identical: two long, nearly equal strings and no clue which
/// characters moved. Shared by the FIX TAGS match review and the assistant's
/// tag review.
struct TagValueDiffView: View {
    @Environment(\.carbon) private var theme
    let current: String
    let proposed: String
    /// Checked for writing: the old value is struck through and the new one lit.
    let checked: Bool

    var body: some View {
        let split = ValueDiff.split(current: current, proposed: proposed)
        HStack(spacing: 6) {
            emphasised(split.current, tint: theme.ink4, changed: theme.ink2)
                .font(CarbonFont.mono(9, weight: .regular))
                .strikethrough(checked)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.ink4)
            emphasised(split.proposed, tint: theme.ink3, changed: checked ? theme.orange : theme.ink2)
                .font(CarbonFont.mono(9, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// One value with its changed span picked out: the shared text recedes, the
    /// difference is tinted and bold.
    private func emphasised(_ split: ValueDiff.Split, tint: Color, changed: Color) -> Text {
        guard !split.isEmpty else {
            return Text(split.head.isEmpty ? "—" : split.head).foregroundColor(tint)
        }
        return Text(split.head).foregroundColor(tint)
            + Text(split.changed)
                .foregroundColor(changed)
                .font(CarbonFont.mono(9, weight: .bold))
            + Text(split.tail).foregroundColor(tint)
    }
}
