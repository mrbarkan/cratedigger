import Foundation

/// How a theme draws the console's controls: the family of looks a theme wears on top
/// of its own palette and geometry. Real Hardware is today's look and the default.
///
/// The raw values are the theme file's spelling and never change. A theme file that
/// names a value this build does not know reads as Real Hardware (see `ThemeDefinition`).
public enum InterfaceStyle: String, Codable, CaseIterable, Sendable {
    case hardware
    case flatHardware
    case softBlocks
    case sticker

    public var displayName: String {
        switch self {
        case .hardware: return "Real Hardware"
        case .flatHardware: return "Flat Hardware"
        case .softBlocks: return "Soft Blocks"
        case .sticker: return "Sticker"
        }
    }

    /// Multiplies the theme's key, well and paper corner radii (the primitives apply it
    /// and clamp to `CarbonGeometry.Bounds.cornerRadius`; the theme's own values are
    /// never rewritten).
    public var radiusScale: Double {
        switch self {
        case .hardware: return 1
        case .flatHardware: return 1.4
        case .softBlocks: return 2.0
        case .sticker: return 1.35
        }
    }

    /// Only Real Hardware has a "flat" switch (Settings turns its content shadows off).
    /// The other styles decide their own shadows, so the switch does not reach them.
    public var honoursFlatSwitch: Bool { self == .hardware }

    /// Whether the style casts the shadows under content (keys, wells, paper).
    public func castsContentShadows(flatSwitchOn: Bool) -> Bool {
        self == .hardware ? !flatSwitchOn : true
    }
}
