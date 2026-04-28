import SwiftUI

public struct ShadowSpec: Equatable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

public struct CarbonTheme: Equatable {
    public enum Mode: String, Equatable {
        case linen
        case carbon
    }

    public let mode: Mode

    public let chassis: Color
    public let chassisHi: Color
    public let chassisLo: Color
    public let chassisDeep: Color

    public let well: Color
    public let wellDeep: Color

    public let paper: Color
    public let paper2: Color

    public let ink: Color
    public let ink2: Color
    public let ink3: Color
    public let ink4: Color
    public let hair: Color

    public let orange: Color
    public let orangeHi: Color
    public let orangeLo: Color
    public let sun: Color
    public let sunHi: Color
    public let sunLo: Color
    public let cyan: Color
    public let cyanGlow: Color
    public let red: Color
    public let indigo: Color

    public let metalHi: Color
    public let metal: Color
    public let metalLo: Color
    public let metalDeep: Color

    public let shadow1: ShadowSpec
    public let shadow2: ShadowSpec

    public let backgroundBase: Color
    public let backgroundGradientStart: Color
    public let backgroundGradientEnd: Color

    public let oledSurface: Color
    public let oledStrokeInner: Color

    public var isDark: Bool { mode == .carbon }
}

public extension CarbonTheme {
    static let linen = CarbonTheme(
        mode: .linen,
        chassis:      Color(hex: 0xE8EDDF),
        chassisHi:    Color(hex: 0xF3F6EC),
        chassisLo:    Color(hex: 0xC8CFBC),
        chassisDeep:  Color(hex: 0x9AA28D),
        well:         Color(hex: 0xCFDBD5),
        wellDeep:     Color(hex: 0xA8B4AF),
        paper:        Color(hex: 0xEEF2E6),
        paper2:       Color(hex: 0xE0E6D4),
        ink:          Color(hex: 0x242423),
        ink2:         Color(hex: 0x333533),
        ink3:         Color(hex: 0x6B6E69),
        ink4:         Color(hex: 0x97998F),
        hair:         Color(hex: 0xB6B9AE),
        orange:       Color(hex: 0xFF7247),
        orangeHi:     Color(hex: 0xFF9170),
        orangeLo:     Color(hex: 0xD04D22),
        sun:          Color(hex: 0xF5CB5C),
        sunHi:        Color(hex: 0xFFE48A),
        sunLo:        Color(hex: 0xC9A23A),
        cyan:         Color(hex: 0x6EC3B8),
        cyanGlow:     Color(hex: 0xB8E6DD),
        red:          Color(hex: 0xC9412A),
        indigo:       Color(hex: 0x2D3A5A),
        metalHi:      Color(hex: 0xF3F6EC),
        metal:        Color(hex: 0xCFD5C6),
        metalLo:      Color(hex: 0x8A907F),
        metalDeep:    Color(hex: 0x3A3D36),
        shadow1: ShadowSpec(color: Color(white: 0.14, opacity: 0.08), radius: 6, y: 2),
        shadow2: ShadowSpec(color: Color(white: 0.14, opacity: 0.18), radius: 36, y: 12),
        backgroundBase:          Color(hex: 0xB3BFB6),
        backgroundGradientStart: Color(hex: 0xC2CDC4),
        backgroundGradientEnd:   Color(hex: 0x9CA8A0),
        oledSurface:     Color(hex: 0x0A0A0A),
        oledStrokeInner: Color(hex: 0x1A1A1A)
    )

    static let carbon = CarbonTheme(
        mode: .carbon,
        chassis:      Color(hex: 0x2A2A28),
        chassisHi:    Color(hex: 0x3A3A37),
        chassisLo:    Color(hex: 0x1A1A18),
        chassisDeep:  Color(hex: 0x0E0E0C),
        well:         Color(hex: 0x161614),
        wellDeep:     Color(hex: 0x0A0A08),
        paper:        Color(hex: 0x1C1C1A),
        paper2:       Color(hex: 0x131311),
        ink:          Color(hex: 0xE8E3D4),
        ink2:         Color(hex: 0xC9C3B1),
        ink3:         Color(hex: 0x807C6F),
        ink4:         Color(hex: 0x5A5750),
        hair:         Color(hex: 0x3A3833),
        orange:       Color(hex: 0xFF7D52),
        orangeHi:     Color(hex: 0xFF9A72),
        orangeLo:     Color(hex: 0xD65428),
        sun:          Color(hex: 0xF5CB5C),
        sunHi:        Color(hex: 0xFFE48A),
        sunLo:        Color(hex: 0xC9A23A),
        cyan:         Color(hex: 0x7ED4C8),
        cyanGlow:     Color(hex: 0xC8EFE8),
        red:          Color(hex: 0xD8482E),
        indigo:       Color(hex: 0x2D3A5A),
        metalHi:      Color(hex: 0x6E6C66),
        metal:        Color(hex: 0x4A4844),
        metalLo:      Color(hex: 0x2A2825),
        metalDeep:    Color(hex: 0x0A0908),
        shadow1: ShadowSpec(color: Color.black.opacity(0.5), radius: 6, y: 2),
        shadow2: ShadowSpec(color: Color.black.opacity(0.6), radius: 36, y: 12),
        backgroundBase:          Color(hex: 0x0A0A08),
        backgroundGradientStart: Color(hex: 0x1A1A16),
        backgroundGradientEnd:   Color(hex: 0x050504),
        oledSurface:     Color(hex: 0x050504),
        oledStrokeInner: Color(hex: 0x0E0E0C)
    )
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
