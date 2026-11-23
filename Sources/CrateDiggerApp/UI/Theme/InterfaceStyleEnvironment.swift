import AppKit
import CrateDiggerCore
import SwiftUI

/// The surface fills Soft Blocks draws with: the theme's own `metal`, `well`
/// and `paper`, each nudged apart from the surface it sits on (keys and wells
/// on the case, paper on the well) by `SoftSeparation`, since Soft Blocks has
/// no bevel or shadow to tell them apart. Worked out once per theme change in
/// `CarbonThemed`, never while drawing.
public struct SoftSurfaces: Equatable {
    public var metal: Color
    public var well: Color
    public var paper: Color
}

private struct InterfaceStyleKey: EnvironmentKey {
    static let defaultValue: InterfaceStyle = .hardware
}

private struct SoftSurfacesKey: EnvironmentKey {
    static let defaultValue: SoftSurfaces? = nil
}

public extension EnvironmentValues {
    /// How the active theme draws its controls. Set by `CarbonThemed` beside
    /// `\.carbon`; Real Hardware wherever no theme has been applied.
    var interfaceStyle: InterfaceStyle {
        get { self[InterfaceStyleKey.self] }
        set { self[InterfaceStyleKey.self] = newValue }
    }

    /// Soft Blocks' separated fills; nil under every other style.
    var softSurfaces: SoftSurfaces? {
        get { self[SoftSurfacesKey.self] }
        set { self[SoftSurfacesKey.self] = newValue }
    }
}

/// What `CarbonThemed` puts in the environment for the interface style,
/// kept apart from the modifier so the decisions are testable.
enum InterfaceStyleDelivery {
    /// The theme's style, unless a DEBUG override names another.
    static func style(for definition: ThemeDefinition?, override: InterfaceStyle?) -> InterfaceStyle {
        override ?? definition?.resolvedStyle ?? .hardware
    }

    /// Soft Blocks' fills for `theme`, or nil for any other style, so no other
    /// style pays for the colour conversion.
    static func softSurfaces(for style: InterfaceStyle, theme: CarbonTheme) -> SoftSurfaces? {
        guard style == .softBlocks else { return nil }
        let chassis = theme.chassis.paletteColor
        let well = theme.well.paletteColor
        return SoftSurfaces(
            metal: Color(palette: SoftSeparation.separated(theme.metal.paletteColor, on: chassis)),
            well: Color(palette: SoftSeparation.separated(well, on: chassis)),
            paper: Color(palette: SoftSeparation.separated(theme.paper.paletteColor, on: well))
        )
    }

    /// The override in force for this process: nil in a release build.
    static var activeOverride: InterfaceStyle? {
        #if DEBUG
        return debugOverride
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// `CRATEDIGGER_STYLE=<raw value>` draws every theme in that style, for
    /// captures (`scripts/style-capture.sh` passes it through). Read once.
    static let debugOverride: InterfaceStyle? =
        debugOverride(from: ProcessInfo.processInfo.environment["CRATEDIGGER_STYLE"])

    /// One of the four raw values exactly; anything else is ignored.
    static func debugOverride(from raw: String?) -> InterfaceStyle? {
        raw.flatMap(InterfaceStyle.init(rawValue:))
    }
    #endif
}

extension Color {
    /// This colour's sRGB components (through `NSColor`, as `themeLuminance`
    /// reads them), for Core's palette maths. A colour that cannot be put in
    /// sRGB reads as opaque black.
    var paletteColor: PaletteColor {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return PaletteColor(r: 0, g: 0, b: 0) }
        return PaletteColor(r: Double(srgb.redComponent), g: Double(srgb.greenComponent),
                            b: Double(srgb.blueComponent), a: Double(srgb.alphaComponent))
    }

    init(palette: PaletteColor) {
        self.init(.sRGB, red: palette.r, green: palette.g, blue: palette.b, opacity: palette.a)
    }
}
