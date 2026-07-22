import SwiftUI

struct FooterShell: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(theme.chassis) // opaque, not Material — see ChassisLayer
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

            HStack(alignment: .center, spacing: 0) {
                FooterLeftCluster()
                    .frame(maxWidth: .infinity, alignment: .leading)
                TransportCluster()
                UtilityCluster()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 26)
        }
        .compositingGroup()
    }
}
