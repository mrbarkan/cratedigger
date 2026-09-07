import CrateDiggerCore
import Foundation

/// Cosmetic equalizer preset surfaced on the OLED now-playing readout, the
/// header view-switcher EQ button, and the footer amber-LCD EQ. There is no
/// real audio EQ in CrateDigger — these values only drive the UI, mirroring the
/// CrateDigger v6 design mockup.
enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    case flat, rock, bass, vocal, treble, jazz

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// 12-band visual shape, each value 0...6 (band 3 = centre / 0 dB).
    var bands: [Int] {
        switch self {
        case .flat:   return [3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3]
        case .rock:   return [5, 5, 4, 3, 2, 2, 2, 3, 4, 5, 5, 6]
        case .bass:   return [6, 6, 5, 5, 4, 3, 2, 2, 1, 1, 1, 1]
        case .vocal:  return [1, 2, 3, 4, 5, 6, 6, 5, 4, 3, 2, 1]
        case .treble: return [1, 1, 1, 1, 2, 2, 3, 4, 5, 5, 6, 6]
        case .jazz:   return [4, 5, 4, 3, 3, 2, 2, 3, 3, 4, 5, 4]
        }
    }

    /// The preset as real per-band gains in dB — band 3 maps to 0 dB and each
    /// segment away from centre is `maxDB/3`. Drives the working equalizer.
    func gainCurve(maxDB: Double = 12) -> [Double] {
        bands.map { (Double($0) - 3) / 3 * maxDB }
    }
}

/// One position the EQ can be in: a built-in preset or one of the three user
/// slots. The header EQ key cycles through a user-chosen subset of these, so
/// they need a single identity that survives being written to preferences.
enum EQSlot: Hashable, Identifiable {
    case preset(EQPreset)
    case user(Int)

    var id: String {
        switch self {
        case .preset(let preset): return preset.rawValue
        case .user(let index):    return "user\(index)"
        }
    }

    init?(id: String) {
        if let preset = EQPreset(rawValue: id) {
            self = .preset(preset)
        } else if id.hasPrefix("user"), let index = Int(id.dropFirst(4)),
                  (0..<CustomEQPreset.slotCount).contains(index) {
            self = .user(index)
        } else {
            return nil
        }
    }

    var isUser: Bool { if case .user = self { return true }; return false }

    /// Every slot the editor shows, in display order.
    static var all: [EQSlot] {
        EQPreset.allCases.map(EQSlot.preset)
            + (0..<CustomEQPreset.slotCount).map(EQSlot.user)
    }
}
