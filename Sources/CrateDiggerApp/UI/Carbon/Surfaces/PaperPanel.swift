import SwiftUI

struct PaperPanel<Content: View>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    /// `nil` uses the active theme's `paperCornerRadius`; pass a value to
    /// override it for this instance regardless of theme.
    var cornerRadius: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? geometry.paperCornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(theme.paper) // opaque, not Material — see ChassisLayer
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.paper.opacity(theme.isDark ? 0.62 : 0.78),
                                theme.paper2.opacity(theme.isDark ? 0.54 : 0.68)
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
                                Color.white.opacity(theme.isDark ? 0.16 : 0.86),
                                theme.hair.opacity(theme.isDark ? 0.58 : 0.70),
                                Color.black.opacity(theme.isDark ? 0.42 : 0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .overlay(
                    shape
                        .stroke(Color.white.opacity(theme.isDark ? 0.05 : 0.34), lineWidth: 1)
                        .blur(radius: 0.8)
                        .offset(y: -1)
                        .mask(shape)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.50 : 0.13), radius: 18, y: 8)
                // (No white top-glow drop shadow: as an *outer* shadow it bled
                // past the rounded corner into the square-clipped bounding box,
                // leaving a light notch. The masked inset highlight above already
                // supplies the top sheen, fully inside the shape.)

            content()
                .clipShape(shape)
        }
        .compositingGroup()
    }
}
