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
