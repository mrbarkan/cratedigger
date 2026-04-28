import SwiftUI

struct PaperPanel<Content: View>: View {
    @Environment(\.carbon) private var theme
    var cornerRadius: CGFloat = CarbonLayout.paperCornerRadius
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.paper, theme.paper2],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    Color.black.opacity(theme.isDark ? 0.6 : 0.08),
                    lineWidth: 1
                )

            content()
        }
        .compositingGroup()
    }
}
