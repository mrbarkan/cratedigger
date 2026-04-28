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
}
