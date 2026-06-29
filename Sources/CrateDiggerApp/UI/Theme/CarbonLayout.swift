import CoreGraphics

public enum CarbonLayout {
    public static let chassisSize  = CGSize(width: 1400, height: 920)
    public static let windowMin    = CGSize(width: 1200, height: 820)

    public static let chassisCornerRadius: CGFloat = 10
    public static let chassisInsetH: CGFloat = 16
    public static let chassisInsetV: CGFloat = 12
    public static let chassisRowGap: CGFloat = 10

    /// Sized to fit the busiest OLED layout (CONVERT — 4 stacked rows: top
    /// status / pipeline / 5-cell readout / ticker). All other modes (now
    /// playing, scan, vu) render at the same frame so the OLED never resizes
    /// across mode swaps.
    public static let headerHeight: CGFloat = 184
    public static let footerHeight: CGFloat = 118

    public static let sidebarWidth: CGFloat = 268
    public static let inspectorWidth: CGFloat = 380
    public static let mainGap: CGFloat = 8

    public static let wellCornerRadius: CGFloat = 12
    public static let wellPadding: CGFloat = 10
    public static let paperCornerRadius: CGFloat = 8

    public static let oledCornerRadius: CGFloat = 16
    public static let oledPaddingH: CGFloat = 20
    public static let oledPaddingV: CGFloat = 12

    public static let viewSwitchWidth: CGFloat = 110
    public static let brandWidth: CGFloat = 200

    public static let transportButtonSize: CGFloat = 44
    public static let playButtonSize: CGFloat = 58
    public static let volumeKnobSize: CGFloat = 76

    public static let keyHeight: CGFloat = 30

    // MARK: - Patch bay (conversion panel)

    /// Standardized switch height for both rocker banks and grid keys, plus
    /// the cycle-button fallback. Lets a row of fixed-width switches and a
    /// single cycle button share the same vertical rhythm.
    public static let patchBayKeyHeight: CGFloat = 30

    /// Default switch width for short labels (4 chars: ALAC, FLAC, OPUS,
    /// 96/128/…/320, 32K/44.1K/…). Drives ViewThatFits — when the row can't
    /// fit `count * patchBayKeyMinWidthSmall` plus gaps, the cycle-button
    /// fallback kicks in.
    public static let patchBayKeyMinWidthSmall: CGFloat = 56

    /// Wider switch for full-text rocker labels (SOURCE, TEMPLATE, ALBUM).
    public static let patchBayKeyMinWidthMedium: CGFloat = 84

    /// Cycle-button height in the narrow-fallback variant.
    public static let patchBayCycleButtonHeight: CGFloat = 44

    /// Vertical gap between rows inside the patch bay panel.
    public static let patchBayRowGap: CGFloat = 14
}
