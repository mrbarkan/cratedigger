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
    public static var overrides: [String: String] = [:]
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
            return Font.custom(override, size: size, relativeTo: .body).weight(weight)
        }
        let postscript: String
        switch weight {
        case .bold, .heavy, .black: postscript = monoBold
        case .semibold:             postscript = monoSemibold
        case .medium:               postscript = monoMedium
        default:                    postscript = monoFamily
        }
        return Font.custom(postscript, size: size, relativeTo: .body)
            .weight(weight)
    }

    public static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let override = ActiveThemeFonts.overrides["sans"] {
            return Font.custom(override, size: size, relativeTo: .body).weight(weight)
        }
        let postscript: String
        switch weight {
        case .black, .heavy:       postscript = sansExtraBold
        case .bold:                postscript = sansBold
        case .semibold:            postscript = sansSemibold
        case .medium:              postscript = sansMedium
        default:                   postscript = sansFamily
        }
        return Font.custom(postscript, size: size, relativeTo: .body)
            .weight(weight)
    }

    public static func display(_ size: CGFloat) -> Font {
        let postscript = ActiveThemeFonts.overrides["display"] ?? displayFamily
        return Font.custom(postscript, size: size, relativeTo: .title)
    }
}
