import Foundation

/// The material a theme gives the chassis. Only one shows at a time; the value
/// stored under `effectKey` in a theme's `effects` is its strength.
public enum ShellMaterial: String, CaseIterable, Sendable {
    case grain, plastic, brushed, blasted, weave

    public var effectKey: String {
        switch self {
        case .grain: return "grain"
        case .plastic: return "shellPlastic"
        case .brushed: return "shellBrushed"
        case .blasted: return "shellBlasted"
        case .weave: return "shellWeave"
        }
    }

    /// First non-zero of plastic, brushed, blasted, weave, then grain last, so
    /// a theme inheriting a grained parent and setting a material gets the
    /// material. Values at or below 0 (or NaN) are off.
    public static func resolve(effects: [String: Double]) -> (material: ShellMaterial, strength: Double)? {
        let priority: [ShellMaterial] = [.plastic, .brushed, .blasted, .weave, .grain]
        for material in priority {
            if let value = effects[material.effectKey], value > 0 {
                return (material, value)
            }
        }
        return nil
    }
}
