import SwiftUI

/// The footer's fixed measures, named once so the compact player's minimum
/// width (`CompactDeckMetrics`) is derived from the same numbers the footer
/// is laid out with.
enum FooterMetrics {
    static let horizontalPadding: CGFloat = 26
    /// Between each pod and the transport.
    static let podGap: CGFloat = 28
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
    /// The locate key reveals the playing track in the browser; the compact
    /// player has no browser, so it leaves the key out.
    var showsLocate: Bool = true

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
            HStack(alignment: .center, spacing: FooterMetrics.podGap) {
                PositionDial(clock: model.playbackClock)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                TransportCluster(showsLocate: showsLocate)
                    // PLAY lands dead centre when both sides of the dome are
                    // the same width: pad the short side by the keys it lacks.
                    // With the locate key there are four keys left of PLAY and
                    // three right; without it (the compact player) the two
                    // sides match and this is zero.
                    .padding(.trailing, transportCentringPadding)
                VolumeKnob(value: $model.playbackVolume)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, FooterMetrics.horizontalPadding)
        }
        .compositingGroup()
    }

    private var transportCentringPadding: CGFloat {
        let keys = TransportCluster.keyCounts(showsLocate: showsLocate)
        return CGFloat(keys.left - keys.right) * (geometry.transportButtonSize + FooterMetrics.transportKeySpacing)
    }
}
