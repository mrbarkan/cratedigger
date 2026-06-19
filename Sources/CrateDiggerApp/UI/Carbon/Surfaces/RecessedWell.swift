import SwiftUI

struct RecessedWell<Content: View>: View {
    @Environment(\.carbon) private var theme
    var cornerRadius: CGFloat = CarbonLayout.wellCornerRadius
    var padding: CGFloat = CarbonLayout.wellPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.well.opacity(theme.isDark ? 0.42 : 0.58),
                                theme.wellDeep.opacity(theme.isDark ? 0.42 : 0.42)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.18 : 0.84),
                                theme.hair.opacity(theme.isDark ? 0.62 : 0.72),
                                Color.black.opacity(theme.isDark ? 0.42 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .overlay(
                    shape
                        .stroke(Color.black.opacity(theme.isDark ? 0.30 : 0.08), lineWidth: 1)
                        .blur(radius: 1.2)
                        .offset(y: 1)
                        .mask(shape)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.46 : 0.14), radius: 18, y: 8)
                .shadow(color: Color.white.opacity(theme.isDark ? 0.00 : 0.42), radius: 1, y: -1)

            content()
                .padding(padding)
        }
        .compositingGroup()
    }
}
