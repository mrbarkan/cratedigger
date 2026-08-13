import CrateDiggerCore
import SwiftUI

/// Font-name overrides from the currently active theme's `fonts` dictionary
/// (`"mono"`/`"sans"`/`"display"` → PostScript name), consulted by
/// `CarbonFont`. Kept as a small holder rather than threaded through every
/// `CarbonFont.mono(...)`/`.sans(...)` call site (there are hundreds, and
/// most are called from view bodies that already re-evaluate when the active
/// theme's environment value changes, so this stays in sync live without a
/// parameter on every call). Only ever written from `CarbonThemed.body` on
/// the main thread, same as every other UI-only global in this file. Empty =
/// every role uses `CarbonFont`'s shipped defaults, i.e. today's exact behavior.
public enum ActiveThemeFonts {
    public static var overrides: [String: ThemeFont] = [:]
}

extension Font.Weight {
    /// Collapses SwiftUI's nine weights onto the four a theme names. Anything
    /// lighter than medium reads as the base face; anything heavier than bold
    /// reads as bold, because that's the heaviest face a family is asked for.
    var themeWeight: ThemeFontWeight {
        switch self {
        case .bold, .heavy, .black: return .bold
        case .semibold:             return .semibold
        case .medium:               return .medium
        default:                    return .regular
        }
    }
}

private extension ThemeFont {
    /// The face to draw, plus whether SwiftUI still has to fake the weight.
    ///
    /// When the theme names a real face for this weight, applying `.weight()`
    /// on top would double-apply it — that mismatch is what AppKit reports as
    /// "Unable to update Font Descriptor's weight".
    func drawing(_ weight: Font.Weight) -> (face: String, synthesize: Font.Weight) {
        let themeWeight = weight.themeWeight
        return face(for: themeWeight) != nil
            ? (resolvedFace(for: themeWeight), .regular)
            : (resolvedFace(for: themeWeight), weight)
    }
}

public enum CarbonFont {
    public static let monoFamily    = "JetBrainsMono-Regular"
    public static let monoMedium    = "JetBrainsMono-Medium"
    public static let monoSemibold  = "JetBrainsMono-SemiBold"
    public static let monoBold      = "JetBrainsMono-Bold"

    public static let sansFamily    = "Inter-Regular"
    public static let sansMedium    = "Inter-Medium"
    public static let sansSemibold  = "Inter-SemiBold"
    public static let sansBold      = "Inter-Bold"
    public static let sansExtraBold = "Inter-ExtraBold"

    public static let displayFamily = "MajorMonoDisplay-Regular"

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let override = ActiveThemeFonts.overrides["mono"] {
            let drawing = override.drawing(weight)
            return Font.custom(drawing.face, size: size, relativeTo: .body).weight(drawing.synthesize)
        }
        // Same rule as the override path: when a real face for this weight is
        // being used, don't ask SwiftUI to apply the weight again on top of it.
        // Only the fallthrough — light/thin, which JetBrains Mono doesn't ship
        // here — still needs synthesising.
        switch weight {
        case .bold, .heavy, .black: return Font.custom(monoBold, size: size, relativeTo: .body)
        case .semibold:             return Font.custom(monoSemibold, size: size, relativeTo: .body)
        case .medium:               return Font.custom(monoMedium, size: size, relativeTo: .body)
        default:                    return Font.custom(monoFamily, size: size, relativeTo: .body).weight(weight)
        }
    }

    public static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let override = ActiveThemeFonts.overrides["sans"] {
            let drawing = override.drawing(weight)
            return Font.custom(drawing.face, size: size, relativeTo: .body).weight(drawing.synthesize)
        }
        switch weight {
        case .black, .heavy: return Font.custom(sansExtraBold, size: size, relativeTo: .body)
        case .bold:          return Font.custom(sansBold, size: size, relativeTo: .body)
        case .semibold:      return Font.custom(sansSemibold, size: size, relativeTo: .body)
        case .medium:        return Font.custom(sansMedium, size: size, relativeTo: .body)
        default:             return Font.custom(sansFamily, size: size, relativeTo: .body).weight(weight)
        }
    }

    public static func display(_ size: CGFloat) -> Font {
        let postscript = ActiveThemeFonts.overrides["display"]?.regular ?? displayFamily
        return Font.custom(postscript, size: size, relativeTo: .title)
    }
}
