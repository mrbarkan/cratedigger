import Foundation

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

    private static func clamp(_ v: Double) -> Double { Swift.max(0, Swift.min(v, 1)) }
}
