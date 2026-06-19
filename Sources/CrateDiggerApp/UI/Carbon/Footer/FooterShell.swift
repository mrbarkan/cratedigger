import SwiftUI

struct FooterShell: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(.thinMaterial)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.chassisHi.opacity(theme.isDark ? 0.24 : 0.42),
                                theme.chassis.opacity(theme.isDark ? 0.26 : 0.34),
                                theme.chassisLo.opacity(theme.isDark ? 0.34 : 0.26)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.12 : 0.62), lineWidth: 1)
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
