import SwiftUI

/// The footer's fixed measures, named once so the compact player's minimum
/// width (`CompactDeckMetrics`) is derived from the same numbers the footer
/// is laid out with.
enum FooterMetrics {
    /// Between the shelf's edge and each pod, and between each pod and the
    /// transport. The two are the same number on purpose: at the narrowest
    /// shelf, where the pods have no room to spare, they are what spaces the
    /// rails, and two values a couple of points apart read as a mistake.
    static let horizontalPadding: CGFloat = 28
    static let podGap: CGFloat = horizontalPadding
    /// POSITION and VOLUME both have this floor.
    static let podMinWidth: CGFloat = 184
    /// `TransportCluster`'s own key spacing.
    static let transportKeySpacing: CGFloat = 11
}

/// The bottom shelf: POSITION dial, transport, VOLUME. The EQ panel and the
/// VU meter used to sit here; the equalizer now opens from the header EQ key,
/// and a small spectrum lives beside the clock on the NOW screen.
struct FooterShell: View {
    @EnvironmentObject private var model: LibraryViewModel
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

            // Each pod sits in the middle of its half of the shelf, so the
            // gap from the shelf's edge to a rail always equals the gap from
            // that rail to the transport, at every window width. The pods used
            // to hug the transport, and once they stopped growing (380 pt) a
            // wide window piled all its spare width between the rails and the
            // shelf's ends. The halves are equal, so both pods grow by the
            // same amount, like a mixer's two faders, and the transport has as
            // many keys either side of PLAY, so the dome lands dead centre.
            HStack(alignment: .center, spacing: FooterMetrics.podGap) {
                PositionDial(clock: model.playbackClock)
                    .frame(maxWidth: .infinity, alignment: .center)
                TransportCluster()
                VolumeKnob(value: $model.playbackVolume)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, FooterMetrics.horizontalPadding)
        }
        .compositingGroup()
    }

}
