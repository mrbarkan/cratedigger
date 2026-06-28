import AppKit
import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system

    public static let userDefaultsKey = "CrateDigger.appearanceMode"
    public static let didChangeNotification = Notification.Name("CrateDigger.appearanceDidChange")

    public var menuTitle: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// The stored appearance preference (defaults to `.system`).
    public static var current: AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? system.rawValue
        return AppearanceMode(rawValue: raw) ?? .system
    }

    /// The stored preference with `.system` resolved to the app's current
    /// effective light/dark — never returns `.system`.
    public static var currentConcrete: AppearanceMode {
        switch current {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .dark : .light
        }
    }
}
