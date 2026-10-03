import CoreGraphics

/// Every measure of the compact player, derived from the active theme's
/// geometry. `CompactDeckView` lays out from it and `WindowFramePlanner`
/// sizes the window from it, so the two cannot disagree.
///
/// The art column copies the brand column's grid: the traffic lights sit in
/// the chassis's top `HeaderKeyMetrics.topInset`, a brand row (lockup plus
/// the expand key) comes next, and the art square takes what is left of the
/// row's height.
struct CompactDeckMetrics: Equatable {
    let geometry: CarbonGeometry

    init(geometry: CarbonGeometry) {
        self.geometry = geometry
    }

    /// Display + gap + footer: the right-hand column's height.
    var rowHeight: CGFloat {
        geometry.headerHeight + geometry.chassisRowGap + geometry.footerHeight
    }

    var artSide: CGFloat {
        rowHeight - HeaderKeyMetrics.topInset - HeaderKeyMetrics.brandRowHeight - HeaderKeyMetrics.rowGap
    }

    /// The transport without the locate key.
    var transportWidth: CGFloat {
        let keys = TransportCluster.keyCounts(showsLocate: false)
        let sideKeys = CGFloat(keys.left + keys.right)
        return sideKeys * geometry.transportButtonSize
            + geometry.playButtonSize
            + sideKeys * FooterMetrics.transportKeySpacing
    }

    var footerMinWidth: CGFloat {
        2 * FooterMetrics.horizontalPadding
            + 2 * FooterMetrics.podMinWidth
            + 2 * FooterMetrics.podGap
            + transportWidth
    }

    /// The window draws under its transparent titlebar, so this is both the
    /// content height and the frame height.
    var windowHeight: CGFloat {
        2 * geometry.chassisInsetV + rowHeight
    }

    var minWindowWidth: CGFloat {
        2 * geometry.chassisInsetH + artSide + geometry.mainGap + footerMinWidth
    }
}
