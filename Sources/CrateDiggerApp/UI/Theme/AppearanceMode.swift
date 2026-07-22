import AppKit
import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Hashable {
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

    /// The NSAppearance for window chrome — nil for `.system`, so assigning it
    /// to `NSWindow.appearance` makes the window follow the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
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
