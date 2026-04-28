import SwiftUI

struct RecessedWell<Content: View>: View {
    @Environment(\.carbon) private var theme
    var cornerRadius: CGFloat = CarbonLayout.wellCornerRadius
    var padding: CGFloat = CarbonLayout.wellPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.wellDeep, theme.well, theme.well],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.black.opacity(theme.isDark ? 0.6 : 0.22), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .blur(radius: 1.5)
                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.clear, Color.white.opacity(theme.isDark ? 0.04 : 0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )

            content()
                .padding(padding)
        }
        .compositingGroup()
    }
}
