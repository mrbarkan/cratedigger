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

            // One cluster, like a deck: the two pods hug the transport instead
            // of being pinned to the shelf's ends, where a wide window left
            // them stranded in bare chassis. The halves are equal, so both
            // pods grow into their half by the same amount, like a mixer's
            // two faders. The transport itself is not symmetric though (see
            // the trailing padding below), so it is the dome, not the
            // cluster's own bounds, that lands dead centre.
            HStack(alignment: .center, spacing: 28) {
                PositionDial(clock: model.playbackClock)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                TransportCluster()
                    // Four keys sit left of PLAY and three right, which put the
                    // dome 28.5 pt right of centre and made the left fader look
                    // stranded. Empty trailing width centres PLAY while both
                    // faders keep the same gap to the window edge: it is
                    // (keysLeft - keysRight) * (transportButtonSize + 11),
                    // where 11 is TransportCluster's own key spacing (not
                    // itself a geometry token, so it stays a literal here
                    // too). Recompute the (4 - 3) if the key counts either
                    // side of PLAY change. Derived from `geometry` rather
                    // than a bare 57, so a theme that retunes
                    // `transportButtonSize` keeps the dome centred instead of
                    // silently drifting out of sync.
                    .padding(.trailing, (4 - 3) * (geometry.transportButtonSize + 11))
                VolumeKnob(value: $model.playbackVolume)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26)
        }
        .compositingGroup()
    }
}
