import SwiftUI

struct ColumnList<Content: View>: View {
    @Environment(\.carbon) private var theme
    let title: String
    let trailing: String
    let headerAccessory: AnyView?
    /// When set, the list scrolls this id into view whenever it changes — keyboard
    /// navigation passes the selected row's id so a moved selection stays visible.
    var scrollTarget: AnyHashable?
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        trailing: String,
        headerAccessory: AnyView? = nil,
        scrollTarget: AnyHashable? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.headerAccessory = headerAccessory
        self.scrollTarget = scrollTarget
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                Spacer(minLength: 8)
                if let headerAccessory {
                    headerAccessory
                }
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        content()
                    }
                }
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ColumnRow<Lead: View, Title: View, Trail: View>: View {
    @Environment(\.carbon) private var theme
    var selected: Bool
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
            LinearGradient(
                colors: [
                    theme.indigo.opacity(theme.isDark ? 0.88 : 0.82),
                    theme.cyan.opacity(theme.isDark ? 0.86 : 0.76)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1),
                alignment: .top
            )
        } else {
            Color.clear
        }
    }
}
