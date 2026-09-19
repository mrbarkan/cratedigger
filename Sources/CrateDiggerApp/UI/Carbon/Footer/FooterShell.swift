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
                    // stranded. 57 pt of empty trailing width centres PLAY
                    // while both faders keep the same gap to the window edge.
                    // Recompute this if the key counts either side of PLAY
                    // change, or if a theme retunes `transportButtonSize`:
                    // it is (keysLeft − keysRight) × (transportButtonSize +
                    // 11), where 11 is TransportCluster's own key spacing
                    // (not itself a geometry token). A theme is free to set
                    // `transportButtonSize` without touching this file, so
                    // this padding can silently drift out of sync and
                    // reintroduce the same off-centre dome.
                    .padding(.trailing, 57)
                VolumeKnob(value: $model.playbackVolume)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26)
        }
        .compositingGroup()
    }
}
