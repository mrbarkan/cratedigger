import SwiftUI

/// One pressing under an expanded release row: an indented row showing the
/// auto format badge and the user's edition label.
struct VersionSubRow: View {
    @Environment(\.carbon) private var theme
    let badge: String
    let edition: String?
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Spacer().frame(width: 18)
                Text(badge)
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .foregroundStyle(selected ? theme.slotInk : theme.ink2)
                if let edition, !edition.isEmpty {
                    Text(edition)
                        .font(CarbonFont.mono(9.5))
                        .foregroundStyle(selected ? theme.slotInk.opacity(0.8) : theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(selected ? theme.orange.opacity(0.15) : Color.clear)
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.05))
                    .frame(height: 1),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
    }
}
