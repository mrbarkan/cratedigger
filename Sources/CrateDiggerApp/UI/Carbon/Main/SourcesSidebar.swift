import SwiftUI

struct SourcesSidebar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader("Library", trailing: "01")

            sidebarItem(
                icon: Image(systemName: "square.stack"),
                title: "All Records",
                count: "\(model.index.allTracks.count)",
                selected: true,
                action: {}
            )

            Spacer()

            loadFolderButton
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text(trailing)
        }
        .font(CarbonFont.mono(8.5, weight: .semibold))
        .tracking(2.2)
        .foregroundStyle(theme.ink4)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func sidebarItem(
        icon: Image,
        title: String,
        count: String,
        selected: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                icon
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor(selected: selected, disabled: disabled))
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(CarbonFont.sans(12.5, weight: .medium))
                    .foregroundStyle(textColor(selected: selected, disabled: disabled))
                Spacer()
                Text(count)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(countColor(selected: selected, disabled: disabled))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(rowBackground(selected: selected))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
    }

    private func textColor(selected: Bool, disabled: Bool) -> Color {
        if disabled { return theme.ink3 }
        if selected { return theme.selectionInk }
        return theme.ink
    }

    private func iconColor(selected: Bool, disabled: Bool) -> Color {
        if disabled { return theme.ink4 }
        if selected { return theme.isDark ? theme.selectionInk : theme.orange }
        return theme.ink3
    }

    private func countColor(selected: Bool, disabled: Bool) -> Color {
        if selected {
            return theme.isDark
                ? theme.selectionInk.opacity(0.7)
                : theme.chassisLo
        }
        return theme.ink3
    }

    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        if selected {
            if theme.isDark {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.orange, theme.orangeLo],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(theme.ink)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var loadFolderButton: some View {
        KeyButton(style: .normal, action: { model.openFolderViaPanel() }) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text("LOAD FOLDER")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .tracking(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 30)
    }
}
