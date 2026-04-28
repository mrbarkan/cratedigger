import SwiftUI

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
        Font.custom(displayFamily, size: size, relativeTo: .title)
    }
}
