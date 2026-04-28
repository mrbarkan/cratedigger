import SwiftUI

struct ChassisLayer<Content: View>: View {
    @Environment(\.carbon) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            backgroundFill
            chassisPlate
                .frame(
                    width: CarbonLayout.chassisSize.width,
                    height: CarbonLayout.chassisSize.height
                )
                .padding(CarbonLayout.chassisInsetH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backgroundFill: some View {
        Rectangle()
            .fill(theme.backgroundBase)
            .overlay(
                LinearGradient(
                    colors: [theme.backgroundGradientStart, theme.backgroundGradientEnd],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(0.6)
            )
            .ignoresSafeArea()
    }

    private var chassisPlate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CarbonLayout.chassisCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.chassisHi, theme.chassis, theme.chassisLo],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CarbonLayout.chassisCornerRadius, style: .continuous)
                        .stroke(theme.isDark ? Color.black.opacity(0.6) : Color.black.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: theme.shadow2.color, radius: theme.shadow2.radius, x: theme.shadow2.x, y: theme.shadow2.y)

            content()
                .padding(.horizontal, CarbonLayout.chassisInsetH)
                .padding(.vertical, CarbonLayout.chassisInsetV)
        }
        .compositingGroup()
    }
}
