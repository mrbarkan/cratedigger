import Foundation

/// Labels DSD streams for display. ffprobe reports a DSD file's audio stream
/// with a `dsd_*` codec and a sample rate that is the 1-bit rate itself
/// (DSD64 = 2 822 400 Hz), not a PCM rate — so the generic format inference
/// would show "DSD_LSBF" / a nonsense kHz. This maps that to "DSD64" etc.
public enum DSDFormat {
    /// Standard 1-bit DSD rates: base 2 822 400 Hz (= 44 100 × 64) × 1/2/4.
    private static let base = 2_822_400

    public static func isDSDCodec(_ codecName: String?) -> Bool {
        guard let name = codecName?.lowercased() else { return false }
        return name.hasPrefix("dsd")
    }

    /// "DSD64" / "DSD128" / "DSD256" for the standard rates, generic "DSD" for
    /// any other rate at or above the DSD64 base, `nil` for ordinary PCM rates.
    public static func label(sampleRateHz: Int?) -> String? {
        guard let rate = sampleRateHz, rate >= base else { return nil }
        switch rate {
        case base: return "DSD64"
        case base * 2: return "DSD128"
        case base * 4: return "DSD256"
        default: return "DSD"
        }
    }
}
