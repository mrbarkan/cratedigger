import Foundation

/// What the OLED's transient volume readout shows (Settings ▸ Playback).
public enum VolumeReadoutUnit: String, CaseIterable, Codable, Sendable {
    case decibels
    case percent

    public var label: String {
        switch self {
        case .decibels: return "Decibels (dB)"
        case .percent:  return "Percent"
        }
    }
}

/// Maps the footer volume fader's 0…1 travel to loudness.
///
/// The fader is linear in dB — `dB = −60 + position·65` — so unity (0 dB) sits at
/// position ≈ 0.923 (the embossed "0" mark) and the top of travel is **+5 dB of
/// real gain**. Because AVPlayer's own volume caps at 1.0, the amplitude is split:
/// the ≤0 dB part rides `player.volume` (0…1), and the >0 dB part is applied as a
/// makeup gain in the audio tap (`AudioLevelTap.setMasterGain`).
public enum VolumeCurve {
    public static let minDB: Double = -60
    public static let maxDB: Double = 5
    /// The fader position where the law reaches 0 dB (unity) — the "0" mark.
    public static let unityPosition: Double = -minDB / (maxDB - minDB)   // 60/65 ≈ 0.923

    /// The fader's dB for a 0…1 position (−60…+5).
    public static func decibels(forPosition position: Double) -> Double {
        minDB + clamp(position) * (maxDB - minDB)
    }

    /// Full linear gain for a fader position (0 … ≈1.78 at +5 dB). Uncapped.
    public static func amplitude(forPosition position: Double) -> Double {
        let p = clamp(position)
        if p <= 0.005 { return 0 }               // −∞
        return pow(10, decibels(forPosition: p) / 20)
    }

    /// The 0…1 part of the gain, for `AVPlayer.volume`.
    public static func playerVolume(forPosition position: Double) -> Double {
        Swift.min(1, amplitude(forPosition: position))
    }

    /// The ≥1 makeup gain (above unity), for the audio tap. 1.0 at/below unity.
    public static func makeupGain(forPosition position: Double) -> Double {
        Swift.max(1, amplitude(forPosition: position))
    }

    /// Short dB label for the OLED readout ("−∞" / "−12 dB" / "0 dB" / "+5 dB").
    public static func label(forPosition position: Double) -> String {
        let p = clamp(position)
        if p <= 0.005 { return "−∞" }
        let db = decibels(forPosition: p)
        if abs(db) < 0.5 { return "0 dB" }
        return db > 0 ? "+\(Int(db.rounded())) dB" : "−\(Int((-db).rounded())) dB"
    }

    /// Half-width of the fader's magnetic pull onto the 0 dB detent. The boost
    /// zone above unity is only 0.077 of travel, so this has to stay small.
    public static let magnetWidth: Double = 0.012

    /// Percent of the travel up to unity: the 0 dB mark reads exactly 100, the
    /// top of travel 108. Where the fader is, not the amplitude (which would
    /// read under 5% for half the travel).
    public static func percent(forPosition position: Double) -> Int {
        Int((clamp(position) / unityPosition * 100).rounded())
    }

    /// The OLED's transient readout. `boostAvailable` is false while a stream or
    /// native DSD plays: neither gets the makeup gain, so the number stops at unity.
    public static func readout(forPosition position: Double,
                               unit: VolumeReadoutUnit,
                               boostAvailable: Bool = true) -> String {
        var p = clamp(position)
        if !boostAvailable { p = Swift.min(p, unityPosition) }
        if p <= 0.005 { return "VOL  MUTE" }
        switch unit {
        case .decibels: return "VOL  \(label(forPosition: p))"
        case .percent:  return "VOL  \(percent(forPosition: p))%"
        }
    }

    /// A Volume Up / Down step. Steps are 0.05 of travel and would walk straight
    /// over unity (0.90 → 0.95), so a step that crosses it stops on it.
    public static func stepped(from position: Double, by delta: Double) -> Double {
        let from = clamp(position)
        let to = clamp(from + delta)
        let crossesUp = from < unityPosition && to > unityPosition
        let crossesDown = from > unityPosition && to < unityPosition
        return (crossesUp || crossesDown) ? unityPosition : to
    }

    private static func clamp(_ v: Double) -> Double { Swift.max(0, Swift.min(v, 1)) }
}
