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

            HStack(alignment: .center, spacing: 24) {
                ModeKeysCluster()
                Spacer()
                TransportCluster()
                Spacer()
                UtilityCluster()
            }
            .padding(.horizontal, 30)
        }
        .compositingGroup()
    }
}
