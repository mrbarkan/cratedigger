import SwiftUI

/// Whether the enclosing browser column currently owns the arrow keys.
/// Published through the environment so `ColumnRow` can mute an unfocused
/// column's selection without every row view and call site having to relay it.
private struct BrowserColumnFocusedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var browserColumnFocused: Bool {
        get { self[BrowserColumnFocusedKey.self] }
        set { self[BrowserColumnFocusedKey.self] = newValue }
    }
}

struct ColumnList<Content: View>: View {
    @Environment(\.carbon) private var theme
    let title: String
    let trailing: String
    let headerAccessory: AnyView?
    /// When set, the list scrolls this id into view whenever it changes — keyboard
    /// navigation passes the selected row's id so a moved selection stays visible.
    var scrollTarget: AnyHashable?
    /// True when the arrow keys currently act on this column. Drives the header
    /// accent + rail below; rows separately mute their selection when this is
    /// false, the way an unfocused NSTableView greys its selected row.
    var isFocused: Bool = false
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        trailing: String,
        headerAccessory: AnyView? = nil,
        scrollTarget: AnyHashable? = nil,
        isFocused: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.headerAccessory = headerAccessory
        self.scrollTarget = scrollTarget
        self.isFocused = isFocused
        self.content = content
    }

    /// The accent that marks keyboard focus — same LED colour the selection slot
    /// uses, so focus and selection read as one system.
    private var focusAccent: Color { theme.isDark ? theme.cyan : theme.orange }

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
            .foregroundStyle(isFocused ? focusAccent : theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.04))
            // A lit rail across the top of the focused column's header. Reads as
            // a powered strip on the hardware rather than a focus ring drawn on
            // top of it, and costs one Rectangle.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(focusAccent)
                    .frame(height: 2)
                    .shadow(color: focusAccent.opacity(0.7), radius: 3)
                    .opacity(isFocused ? 1 : 0)
            }
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.07))
                    .frame(height: 1),
                alignment: .bottom
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)

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
        .environment(\.browserColumnFocused, isFocused)
    }
}

struct ColumnRow<Lead: View, Title: View, Trail: View>: View {
    @Environment(\.carbon) private var theme
    /// Whether this row's column owns the keyboard. A selected row in an
    /// unfocused column stays visible but dims, so at a glance you can tell
    /// which of the three selections the arrow keys will move.
    @Environment(\.browserColumnFocused) private var columnFocused
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
            .padding(.horizontal, 10)
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
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onActivate?()
            }
        )
    }

    @ViewBuilder
    private var selectedBackground: some View {
        if selected {
            CarbonSelectionSlot(cornerRadius: 0)
                .opacity(columnFocused ? 1 : 0.45)
        } else {
            Color.clear
        }
    }
}
