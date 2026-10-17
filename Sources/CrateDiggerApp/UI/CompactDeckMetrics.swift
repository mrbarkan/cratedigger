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

    /// The transport: three keys either side of the PLAY dome.
    var transportWidth: CGFloat {
        let sideKeys = CGFloat(2 * TransportCluster.keysPerSide)
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

    /// `StatusLED`'s key: the lamp sits in an 18 pt cap and socket, and the
    /// whole key is what you see and click.
    static let statusLampHitSide: CGFloat = StatusLED.keySide

    /// Where the titlebar status LED's lamp is centred in compact, measured
    /// in from the window's leading edge. The full layout puts the lamp in the
    /// titlebar's trailing corner, above the logo column; compact has no
    /// column there and the display runs out to the margin, so the corner
    /// lamp would sit on the glass. Here it moves over the art column, the
    /// traffic lights' opposite number across that column: in the titlebar
    /// strip, level with them, the key's edge flush with the column's
    /// trailing edge and so with the expand key under it.
    var statusLampCenterX: CGFloat {
        geometry.chassisInsetH + artSide - Self.statusLampHitSide / 2
    }
}
