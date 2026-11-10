import AppKit
import CrateDiggerCore
import SwiftUI

/// The compact player's own column: the art under a brand row that carries
/// the expand key. The display and the transport beside it are the console's
/// own, placed by `ConsoleStageView`. Every measure comes from
/// `CompactDeckMetrics`, which the window controller sizes the window from.
struct CompactArtColumn: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel
    /// The backing scale the cover screen is planned for. From the
    /// environment, so a move to a display of another scale re-plans it.
    @Environment(\.displayScale) private var displayScale

    /// Whether the art well pushed the pointing hand, so it only ever pops
    /// its own cursor.
    @State private var pushedCursor = false

    var body: some View {
        let metrics = CompactDeckMetrics(geometry: geometry)
        VStack(alignment: .leading, spacing: HeaderKeyMetrics.rowGap) {
            HStack(spacing: 8) {
                BrandLockup(typeSize: 11)
                Spacer(minLength: 0)
                expandKey
            }
            .frame(height: HeaderKeyMetrics.brandRowHeight)
            artWell
                .frame(width: metrics.artSide, height: metrics.artSide)
        }
        .padding(.top, HeaderKeyMetrics.topInset)
        .frame(width: metrics.artSide)
    }

    /// rectangle.expand: the same switch as the brand block's compact key,
    /// the other way — back to the whole console.
    private var expandKey: some View {
        Button {
            ClickPlayer.shared.play(.key)
            model.expandToFull()
        } label: {
            Image(systemName: "rectangle.expand.vertical")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.chassisInk)
                .padding(.horizontal, 6)
                // The style's socket adds its lip outside this; the key keeps
                // the brand row's 20pt.
                .frame(height: 20 - 2 * ChassisKeyMetrics.seat)
                .contentShape(Rectangle())
        }
        .buttonStyle(.chassisKey)
        .carbonTip("Full console (⌥⇧⌘M)")
        .accessibilityLabel("Expand to the full console")
    }

    private var artWell: some View {
        let clickable = model.nowPlayingAlbum != nil
        return artHousing
        .contentShape(Rectangle())
        .onTapGesture {
            guard clickable else { return }
            ClickPlayer.shared.play(.key)
            model.showNowPlayingArtwork()
        }
        .onHover { inside in
            if inside, clickable, !pushedCursor {
                NSCursor.pointingHand.push()
                pushedCursor = true
            } else if !inside, pushedCursor {
                NSCursor.pop()
                pushedCursor = false
            }
        }
        .carbonTip(clickable ? "View artwork" : "")
        .accessibilityAddTraits(clickable ? .isButton : [])
        .accessibilityLabel(clickable ? "Album artwork. Opens the artwork viewer." : "Album artwork")
    }

    /// With a cover screen look, the art is an LCD set into the shell behind
    /// its bezel; otherwise the recessed well it has always been.
    @ViewBuilder
    private var artHousing: some View {
        let metrics = CompactDeckMetrics(geometry: geometry)
        if let screen = CoverScreenSpec(theme: theme, side: metrics.artSide, scale: displayScale) {
            CoverScreenBezel(spec: screen, cornerRadius: geometry.wellCornerRadius) {
                NowPlayingCover(model: model, maxPixel: 600, screen: screen) { Color.clear }
            }
        } else {
            RecessedWell(padding: 0) {
                // An empty well when nothing plays: the display already says so.
                NowPlayingCover(model: model, maxPixel: 600) { Color.clear }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
            }
        }
    }
}
