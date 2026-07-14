import CoreGraphics
import CrateDiggerCore

/// The themable counterpart of `CarbonLayout`: per-theme geometry (corner
/// radii, control sizes, pane widths) injected via `\.carbonGeometry`
/// alongside `\.carbon`. `CarbonLayout`'s constants remain the *default*
/// values (see `CarbonGeometry.standard`) and the source of truth for
/// window-level sizing (`chassisSize`/`windowMin`) that lives outside
/// SwiftUI's environment reach (AppKit window frame/min-size constraints).
///
/// Unlike colors, bad geometry can break layout rather than just look ugly,
/// so every field is clamped to a safe range at construction time — a theme
/// that requests `playButtonSize: 999` gets the clamped maximum, not a
/// broken transport cluster.
public struct CarbonGeometry: Equatable {
    public var chassisCornerRadius: CGFloat
    public var chassisInsetH: CGFloat
    public var chassisInsetV: CGFloat
    public var chassisRowGap: CGFloat

    public var headerHeight: CGFloat
    public var footerHeight: CGFloat

    public var sidebarWidth: CGFloat
    public var inspectorWidth: CGFloat
    public var mainGap: CGFloat

    public var wellCornerRadius: CGFloat
    public var wellPadding: CGFloat
    public var paperCornerRadius: CGFloat

    public var oledCornerRadius: CGFloat
    public var oledPaddingH: CGFloat
    public var oledPaddingV: CGFloat

    public var viewSwitchWidth: CGFloat
    public var brandWidth: CGFloat

    public var transportButtonSize: CGFloat
    public var playButtonSize: CGFloat

    public var keyHeight: CGFloat

    public var patchBayKeyHeight: CGFloat
    public var patchBayKeyMinWidthSmall: CGFloat
    public var patchBayKeyMinWidthMedium: CGFloat
    public var patchBayCycleButtonHeight: CGFloat
    public var patchBayRowGap: CGFloat

    public init(
        chassisCornerRadius: CGFloat,
        chassisInsetH: CGFloat,
        chassisInsetV: CGFloat,
        chassisRowGap: CGFloat,
        headerHeight: CGFloat,
        footerHeight: CGFloat,
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        mainGap: CGFloat,
        wellCornerRadius: CGFloat,
        wellPadding: CGFloat,
        paperCornerRadius: CGFloat,
        oledCornerRadius: CGFloat,
        oledPaddingH: CGFloat,
        oledPaddingV: CGFloat,
        viewSwitchWidth: CGFloat,
        brandWidth: CGFloat,
        transportButtonSize: CGFloat,
        playButtonSize: CGFloat,
        keyHeight: CGFloat,
        patchBayKeyHeight: CGFloat,
        patchBayKeyMinWidthSmall: CGFloat,
        patchBayKeyMinWidthMedium: CGFloat,
        patchBayCycleButtonHeight: CGFloat,
        patchBayRowGap: CGFloat
    ) {
        self.chassisCornerRadius = Self.Bounds.cornerRadius.clamp(chassisCornerRadius)
        self.chassisInsetH = Self.Bounds.inset.clamp(chassisInsetH)
        self.chassisInsetV = Self.Bounds.inset.clamp(chassisInsetV)
        self.chassisRowGap = Self.Bounds.gap.clamp(chassisRowGap)
        self.headerHeight = Self.Bounds.headerFooterHeight.clamp(headerHeight)
        self.footerHeight = Self.Bounds.headerFooterHeight.clamp(footerHeight)
        self.sidebarWidth = Self.Bounds.paneWidth.clamp(sidebarWidth)
        self.inspectorWidth = Self.Bounds.paneWidth.clamp(inspectorWidth)
        self.mainGap = Self.Bounds.gap.clamp(mainGap)
        self.wellCornerRadius = Self.Bounds.cornerRadius.clamp(wellCornerRadius)
        self.wellPadding = Self.Bounds.inset.clamp(wellPadding)
        self.paperCornerRadius = Self.Bounds.cornerRadius.clamp(paperCornerRadius)
        self.oledCornerRadius = Self.Bounds.cornerRadius.clamp(oledCornerRadius)
        self.oledPaddingH = Self.Bounds.inset.clamp(oledPaddingH)
        self.oledPaddingV = Self.Bounds.inset.clamp(oledPaddingV)
        self.viewSwitchWidth = Self.Bounds.smallControl.clamp(viewSwitchWidth)
        self.brandWidth = Self.Bounds.paneWidth.clamp(brandWidth)
        self.transportButtonSize = Self.Bounds.button.clamp(transportButtonSize)
        self.playButtonSize = Self.Bounds.button.clamp(playButtonSize)
        self.keyHeight = Self.Bounds.smallControl.clamp(keyHeight)
        self.patchBayKeyHeight = Self.Bounds.smallControl.clamp(patchBayKeyHeight)
        self.patchBayKeyMinWidthSmall = Self.Bounds.smallControl.clamp(patchBayKeyMinWidthSmall)
        self.patchBayKeyMinWidthMedium = Self.Bounds.smallControl.clamp(patchBayKeyMinWidthMedium)
        self.patchBayCycleButtonHeight = Self.Bounds.button.clamp(patchBayCycleButtonHeight)
        self.patchBayRowGap = Self.Bounds.gap.clamp(patchBayRowGap)
    }

    /// Safe ranges a theme's geometry values are clamped into. Generous
    /// enough for real restyling (a much chunkier or much sleeker transport
    /// cluster) without letting a hostile or careless theme collapse
    /// `MainShell`'s three-pane layout or produce a zero/negative frame.
    private enum Bounds {
        static let cornerRadius: ClosedRange<CGFloat> = 0...40
        static let inset: ClosedRange<CGFloat> = 0...32
        static let gap: ClosedRange<CGFloat> = 0...32
        static let headerFooterHeight: ClosedRange<CGFloat> = 60...240
        static let paneWidth: ClosedRange<CGFloat> = 120...480
        static let smallControl: ClosedRange<CGFloat> = 16...96
        static let button: ClosedRange<CGFloat> = 32...120
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

public extension CarbonGeometry {
    /// `CarbonLayout`'s current constants, unchanged — the default geometry
    /// for both built-in themes and for any theme that omits `geometry`.
    static let standard = CarbonGeometry(
        chassisCornerRadius: CarbonLayout.chassisCornerRadius,
        chassisInsetH: CarbonLayout.chassisInsetH,
        chassisInsetV: CarbonLayout.chassisInsetV,
        chassisRowGap: CarbonLayout.chassisRowGap,
        headerHeight: CarbonLayout.headerHeight,
        footerHeight: CarbonLayout.footerHeight,
        sidebarWidth: CarbonLayout.sidebarWidth,
        inspectorWidth: CarbonLayout.inspectorWidth,
        mainGap: CarbonLayout.mainGap,
        wellCornerRadius: CarbonLayout.wellCornerRadius,
        wellPadding: CarbonLayout.wellPadding,
        paperCornerRadius: CarbonLayout.paperCornerRadius,
        oledCornerRadius: CarbonLayout.oledCornerRadius,
        oledPaddingH: CarbonLayout.oledPaddingH,
        oledPaddingV: CarbonLayout.oledPaddingV,
        viewSwitchWidth: CarbonLayout.viewSwitchWidth,
        brandWidth: CarbonLayout.brandWidth,
        transportButtonSize: CarbonLayout.transportButtonSize,
        playButtonSize: CarbonLayout.playButtonSize,
        keyHeight: CarbonLayout.keyHeight,
        patchBayKeyHeight: CarbonLayout.patchBayKeyHeight,
        patchBayKeyMinWidthSmall: CarbonLayout.patchBayKeyMinWidthSmall,
        patchBayKeyMinWidthMedium: CarbonLayout.patchBayKeyMinWidthMedium,
        patchBayCycleButtonHeight: CarbonLayout.patchBayCycleButtonHeight,
        patchBayRowGap: CarbonLayout.patchBayRowGap
    )

    /// Converts a (possibly partial) `ThemeDefinition.geometry` dictionary
    /// into a fully-populated, clamped `CarbonGeometry`, filling any omitted
    /// token from `resolvedBase` (normally `.standard`).
    init(definition: ThemeDefinition, resolvedBase: CarbonGeometry = .standard) {
        func value(_ key: String, _ fallback: CGFloat) -> CGFloat {
            guard let raw = definition.geometry?[key] else { return fallback }
            return CGFloat(raw)
        }

        self.init(
            chassisCornerRadius: value("chassisCornerRadius", resolvedBase.chassisCornerRadius),
            chassisInsetH: value("chassisInsetH", resolvedBase.chassisInsetH),
            chassisInsetV: value("chassisInsetV", resolvedBase.chassisInsetV),
            chassisRowGap: value("chassisRowGap", resolvedBase.chassisRowGap),
            headerHeight: value("headerHeight", resolvedBase.headerHeight),
            footerHeight: value("footerHeight", resolvedBase.footerHeight),
            sidebarWidth: value("sidebarWidth", resolvedBase.sidebarWidth),
            inspectorWidth: value("inspectorWidth", resolvedBase.inspectorWidth),
            mainGap: value("mainGap", resolvedBase.mainGap),
            wellCornerRadius: value("wellCornerRadius", resolvedBase.wellCornerRadius),
            wellPadding: value("wellPadding", resolvedBase.wellPadding),
            paperCornerRadius: value("paperCornerRadius", resolvedBase.paperCornerRadius),
            oledCornerRadius: value("oledCornerRadius", resolvedBase.oledCornerRadius),
            oledPaddingH: value("oledPaddingH", resolvedBase.oledPaddingH),
            oledPaddingV: value("oledPaddingV", resolvedBase.oledPaddingV),
            viewSwitchWidth: value("viewSwitchWidth", resolvedBase.viewSwitchWidth),
            brandWidth: value("brandWidth", resolvedBase.brandWidth),
            transportButtonSize: value("transportButtonSize", resolvedBase.transportButtonSize),
            playButtonSize: value("playButtonSize", resolvedBase.playButtonSize),
            keyHeight: value("keyHeight", resolvedBase.keyHeight),
            patchBayKeyHeight: value("patchBayKeyHeight", resolvedBase.patchBayKeyHeight),
            patchBayKeyMinWidthSmall: value("patchBayKeyMinWidthSmall", resolvedBase.patchBayKeyMinWidthSmall),
            patchBayKeyMinWidthMedium: value("patchBayKeyMinWidthMedium", resolvedBase.patchBayKeyMinWidthMedium),
            patchBayCycleButtonHeight: value("patchBayCycleButtonHeight", resolvedBase.patchBayCycleButtonHeight),
            patchBayRowGap: value("patchBayRowGap", resolvedBase.patchBayRowGap)
        )
    }
}
