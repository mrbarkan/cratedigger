import Foundation

public enum MediaFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case cd = "CD"
    case vinyl = "Vinyl"
    case digital = "Digital"
}
