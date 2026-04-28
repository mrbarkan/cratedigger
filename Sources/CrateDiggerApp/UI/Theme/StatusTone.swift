import SwiftUI

public enum StatusTone: Sendable {
    case neutral
    case info
    case success
    case warning
    case error
}

public extension CarbonTheme {
    func statusColor(for tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return ink3
        case .info:    return cyan
        case .success: return Color(hex: 0x238636)
        case .warning: return sun
        case .error:   return red
        }
    }
}
