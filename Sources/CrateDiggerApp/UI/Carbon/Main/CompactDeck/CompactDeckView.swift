import AppKit
import CrateDiggerCore
import SwiftUI

/// The compact player: one rack unit. Art on the left under a brand row
/// that carries the expand key; the console's own display (pinned to NOW)
/// over its own footer on the right. Every measure comes from
/// `CompactDeckMetrics`, which the window controller sizes the window from.
struct CompactDeckView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    /// Whether the art well pushed the pointing hand, so it only ever pops
    /// its own cursor.
    @State private var pushedCursor = false

    var body: some View {
        let metrics = CompactDeckMetrics(geometry: geometry)
        HStack(alignment: .top, spacing: geometry.mainGap) {
            artColumn(metrics)
                .frame(width: metrics.artSide)
            VStack(spacing: geometry.chassisRowGap) {
                OLEDDisplay()
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.headerHeight)
                    .environment(\.oledScreenOverride, .nowPlaying)
                FooterShell(showsLocate: false)
                    .frame(height: geometry.footerHeight)
            }
        }
    }

    // MARK: Art column

    private func artColumn(_ metrics: CompactDeckMetrics) -> some View {
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
    }

    /// pip.exit: the same switch as the brand block's Mini Player pip, the
    /// other way — back to the whole console.
    private var expandKey: some View {
        Button {
            ClickPlayer.shared.play(.key)
            model.expandToFull()
        } label: {
            Image(systemName: "pip.exit")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.chassisInk)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(ChromeChassis(theme: theme, cornerRadius: geometry.keyCornerRadius))
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Full console (⌥⇧⌘M)")
        .accessibilityLabel("Expand to the full console")
    }

    private var artWell: some View {
        let clickable = model.nowPlayingAlbum != nil
        return RecessedWell(padding: 0) {
            // An empty well when nothing plays: the display already says so.
            NowPlayingCover(model: model, maxPixel: 600) { Color.clear }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
        }
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
}
