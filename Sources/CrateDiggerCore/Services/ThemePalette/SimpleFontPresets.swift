import Foundation

public struct SimpleFontPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let font: ThemeFont
}

/// The five faces offered per font role in Simple mode. Only faces that exist as a
/// bundled font or on every Mac, each weight named where the family ships it so
/// nothing is synthesised. PostScript names verified with CoreText on macOS 27.
///
/// Silkscreen and Pixel Operator Mono 8 ship in Llama '97's `Fonts/` folder, not the
/// app's own, so they draw only once something registers them (see the Task 5 report).
public enum SimpleFontPresets {
    private static func preset(_ id: String, _ label: String, _ regular: String, light: String? = nil,
                               medium: String? = nil, semibold: String? = nil, bold: String? = nil) -> SimpleFontPreset {
        SimpleFontPreset(id: id, label: label,
                         font: ThemeFont(regular: regular, light: light, medium: medium, semibold: semibold, bold: bold))
    }

    /// Writes the `display` role.
    public static let screenTitles: [SimpleFontPreset] = [
        preset("majorMono", "Major Mono Display", "MajorMonoDisplay-Regular"),
        preset("silkscreen", "Silkscreen", "Silkscreen-Regular", bold: "Silkscreen-Bold"),
        preset("futura", "Futura", "Futura-Medium", bold: "Futura-Bold"),
        preset("dinCondensed", "DIN Condensed", "DINCondensed-Bold", bold: "DINCondensed-Bold"),
        preset("avenirLight", "Avenir Next Light", "AvenirNext-UltraLight", bold: "AvenirNext-Regular"),
    ]

    /// Writes the `mono` role.
    public static let labels: [SimpleFontPreset] = [
        preset("jetBrainsMono", "JetBrains Mono", "JetBrainsMono-Regular", medium: "JetBrainsMono-Medium",
               semibold: "JetBrainsMono-SemiBold", bold: "JetBrainsMono-Bold"),
        preset("pixelOperator", "Pixel Operator Mono 8", "PixelOperatorMono8", bold: "PixelOperatorMono8-Bold"),
        // SF Mono has no PostScript name an app can ask for (CoreText answers Helvetica).
        preset("monaco", "Monaco", "Monaco"),
        preset("menlo", "Menlo", "Menlo-Regular", bold: "Menlo-Bold"),
        preset("andaleMono", "Andale Mono", "AndaleMono"),
    ]

    /// Writes the `sans` role.
    public static let interface: [SimpleFontPreset] = [
        preset("inter", "Inter", "Inter-Regular", medium: "Inter-Medium", semibold: "Inter-SemiBold", bold: "Inter-Bold"),
        preset("sfPro", "SF Pro", ".AppleSystemUIFont"),
        preset("avenirNext", "Avenir Next", "AvenirNext-Regular", light: "AvenirNext-UltraLight",
               medium: "AvenirNext-Medium", semibold: "AvenirNext-DemiBold", bold: "AvenirNext-Bold"),
        preset("helveticaNeue", "Helvetica Neue", "HelveticaNeue", light: "HelveticaNeue-Light",
               medium: "HelveticaNeue-Medium", bold: "HelveticaNeue-Bold"),
        preset("gillSans", "Gill Sans", "GillSans", light: "GillSans-Light", semibold: "GillSans-SemiBold",
               bold: "GillSans-Bold"),
    ]
}
