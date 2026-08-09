import Foundation

public enum MediaFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case cd = "CD"
    case vinyl = "Vinyl"
    case cassette = "Cassette"
    case digital = "Digital"

    /// SF Symbol shown beside an album that's been tagged with this medium.
    public var symbolName: String {
        switch self {
        case .cd:       return "opticaldisc"
        case .vinyl:    return "smallcircle.filled.circle"
        case .cassette: return "recordingtape"
        case .digital:  return "waveform"
        }
    }
}
