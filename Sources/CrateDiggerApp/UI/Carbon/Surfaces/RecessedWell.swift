import SwiftUI

struct RecessedWell<Content: View>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    /// `nil` uses the active theme's `wellCornerRadius`/`wellPadding`; pass a
    /// value to override either for this instance regardless of theme.
    var cornerRadius: CGFloat? = nil
    var padding: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? geometry.wellCornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(theme.well) // opaque, not Material — see ChassisLayer
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
                // (No white top-glow drop shadow — it bled past the rounded corner
                // into the square-clipped bounds as a light notch. The masked inset
                // highlight above supplies the sheen, fully inside the shape.)

            content()
                .padding(padding ?? geometry.wellPadding)
        }
        .compositingGroup()
    }
}
