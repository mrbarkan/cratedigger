import SwiftUI

struct FooterShell: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.chassis, theme.chassisLo],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(theme.isDark ? 0.05 : 0.4), lineWidth: 1)
                )

            HStack {
                placeholderCluster("Modes")
                Spacer()
                placeholderCluster("Transport")
                Spacer()
                placeholderCluster("Volume")
            }
            .padding(.horizontal, 40)
        }
        .compositingGroup()
    }

    private func placeholderCluster(_ label: String) -> some View {
        Text(label.uppercased())
            .font(CarbonFont.mono(9, weight: .bold))
            .tracking(2.2)
            .foregroundStyle(theme.ink3)
    }
}
