import Foundation

/// Maps the AMBIENT fader's 0…1 travel to the gain applied to the microphone.
///
/// The same dB-linear law as `VolumeCurve`, with more headroom: a laptop mic
/// hearing a room from across the desk is quiet, so the top of travel is
/// +12 dB rather than the VOLUME fader's +5. Unity sits at 60/72 of travel.
public enum AmbientLevelCurve {
    public static let minDB: Double = -60
    public static let maxDB: Double = 12
    /// The fader position where the law reaches 0 dB, the "0" mark.
    public static let unityPosition: Double = -minDB / (maxDB - minDB)   // 60/72 ≈ 0.833

    public static func decibels(forPosition position: Double) -> Double {
        minDB + clamp(position) * (maxDB - minDB)
    }

    /// Linear gain for a fader position: 0 at the bottom, ≈3.98 at +12 dB.
    public static func amplitude(forPosition position: Double) -> Double {
        let p = clamp(position)
        if p <= 0.005 { return 0 }               // −∞
        return pow(10, decibels(forPosition: p) / 20)
    }

    /// Short dB label for the screen ("−∞" / "−12 dB" / "0 dB" / "+12 dB").
    public static func label(forPosition position: Double) -> String {
        let p = clamp(position)
        if p <= 0.005 { return "−∞" }
        let db = decibels(forPosition: p)
        if abs(db) < 0.5 { return "0 dB" }
        return db > 0 ? "+\(Int(db.rounded())) dB" : "−\(Int((-db).rounded())) dB"
    }

    private static func clamp(_ v: Double) -> Double { Swift.max(0, Swift.min(v, 1)) }
}
