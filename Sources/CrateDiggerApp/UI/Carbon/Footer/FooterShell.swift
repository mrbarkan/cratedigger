import SwiftUI

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

            HStack(alignment: .center, spacing: 0) {
                PositionDial(clock: model.playbackClock)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TransportCluster()
                VolumeKnob(value: $model.playbackVolume)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 26)
        }
        .compositingGroup()
    }
}
