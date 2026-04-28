import SwiftUI

struct ColumnList<Content: View>: View {
    @Environment(\.carbon) private var theme
    let title: String
    let trailing: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                Spacer()
                Text(trailing)
            }
            .font(CarbonFont.mono(8.5, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(theme.ink3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.04))
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.07))
                    .frame(height: 1),
                alignment: .bottom
            )

            ScrollView {
                LazyVStack(spacing: 0) {
                    content()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ColumnRow<Lead: View, Title: View, Trail: View>: View {
    @Environment(\.carbon) private var theme
    var selected: Bool
    var isPlaying: Bool
    var onSelect: () -> Void
    var onActivate: (() -> Void)?
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trail: () -> Trail

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                lead()
                    .frame(width: 16, alignment: .center)
                title()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                trail()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedBackground)
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.05))
                    .frame(height: 1),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onActivate?()
            }
        )
    }

    @ViewBuilder
    private var selectedBackground: some View {
        if selected {
            if theme.isDark {
                LinearGradient(
                    colors: [theme.orange, theme.orangeLo],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1),
                    alignment: .top
                )
            } else {
                theme.ink
            }
        } else {
            Color.clear
        }
    }
}
