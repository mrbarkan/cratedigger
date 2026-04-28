import SwiftUI

struct HeaderShell: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: 16) {
            placeholder("Brand")
                .frame(width: CarbonLayout.brandWidth)
            placeholder("OLED")
                .frame(maxWidth: .infinity)
            placeholder("Views")
                .frame(width: CarbonLayout.viewSwitchWidth)
        }
    }

    private func placeholder(_ label: String) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.06))
            .overlay(
                Text(label)
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(theme.ink3)
            )
    }
}
