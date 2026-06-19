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

    /// Foreground (text/icon) color when laid over a selected row background.
    /// Centralized so row views and the sources sidebar keep selected text
    /// readable over the accent gradients.
    public let selectionInk: Color

    public var isDark: Bool { mode == .carbon }
}

public extension CarbonTheme {
    static let linen = CarbonTheme(
        mode: .linen,
        chassis:      Color(hex: 0xF5F8FA),
        chassisHi:    Color(hex: 0xFFFFFF),
        chassisLo:    Color(hex: 0xD7E1E5),
        chassisDeep:  Color(hex: 0x9CAAB0),
        well:         Color(hex: 0xE9F1F4),
        wellDeep:     Color(hex: 0xC8D5DA),
        paper:        Color(hex: 0xFAFCFD),
        paper2:       Color(hex: 0xEEF4F7),
        ink:          Color(hex: 0x12171C),
        ink2:         Color(hex: 0x313E47),
        ink3:         Color(hex: 0x657580),
        ink4:         Color(hex: 0x98A5AB),
        hair:         Color(hex: 0xC7D2D7),
        orange:       Color(hex: 0xFF6236),
        orangeHi:     Color(hex: 0xFF956F),
        orangeLo:     Color(hex: 0xD7441E),
        sun:          Color(hex: 0xF4C84A),
        sunHi:        Color(hex: 0xFFE58A),
        sunLo:        Color(hex: 0xC99E2F),
        cyan:         Color(hex: 0x3AA8B8),
        cyanGlow:     Color(hex: 0xBDEEF2),
        red:          Color(hex: 0xE2473F),
        indigo:       Color(hex: 0x4B6FCB),
        metalHi:      Color(hex: 0xFFFFFF),
        metal:        Color(hex: 0xDDE8EC),
        metalLo:      Color(hex: 0xABB9C0),
        metalDeep:    Color(hex: 0x5F6D75),
        shadow1: ShadowSpec(color: Color(white: 0.06, opacity: 0.10), radius: 10, y: 3),
        shadow2: ShadowSpec(color: Color(white: 0.05, opacity: 0.24), radius: 48, y: 22),
        backgroundBase:          Color(hex: 0xDCE9EC),
        backgroundGradientStart: Color(hex: 0xF2F8F9),
        backgroundGradientEnd:   Color(hex: 0xC7D8DF),
        oledSurface:     Color(hex: 0x0A0A0A),
        oledStrokeInner: Color(hex: 0x1A1A1A),
        selectionInk:    Color(hex: 0xFFFFFF)
    )

    static let carbon = CarbonTheme(
        mode: .carbon,
        chassis:      Color(hex: 0x171C22),
        chassisHi:    Color(hex: 0x2B3540),
        chassisLo:    Color(hex: 0x0C0F13),
        chassisDeep:  Color(hex: 0x05070A),
        well:         Color(hex: 0x121A22),
        wellDeep:     Color(hex: 0x070A0E),
        paper:        Color(hex: 0x111820),
        paper2:       Color(hex: 0x0A0E13),
        ink:          Color(hex: 0xF3F7F7),
        ink2:         Color(hex: 0xC8D4D9),
        ink3:         Color(hex: 0x82929B),
        ink4:         Color(hex: 0x56636C),
        hair:         Color(hex: 0x26333C),
        orange:       Color(hex: 0xFF6D3F),
        orangeHi:     Color(hex: 0xFFA07C),
        orangeLo:     Color(hex: 0xD94C25),
        sun:          Color(hex: 0xF4CA54),
        sunHi:        Color(hex: 0xFFE894),
        sunLo:        Color(hex: 0xC79D30),
        cyan:         Color(hex: 0x45C7BD),
        cyanGlow:     Color(hex: 0xBEF4EF),
        red:          Color(hex: 0xEA554C),
        indigo:       Color(hex: 0x7282E8),
        metalHi:      Color(hex: 0x56626B),
        metal:        Color(hex: 0x303A43),
        metalLo:      Color(hex: 0x151A20),
        metalDeep:    Color(hex: 0x05070A),
        shadow1: ShadowSpec(color: Color.black.opacity(0.52), radius: 12, y: 3),
        shadow2: ShadowSpec(color: Color.black.opacity(0.72), radius: 54, y: 24),
        backgroundBase:          Color(hex: 0x080A0E),
        backgroundGradientStart: Color(hex: 0x18232C),
        backgroundGradientEnd:   Color(hex: 0x030406),
        oledSurface:     Color(hex: 0x050504),
        oledStrokeInner: Color(hex: 0x0E0E0C),
        selectionInk:    Color(hex: 0xFFFFFF)
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
