import Foundation

extension Double {
    /// Duration as `m:ss` — seconds rounded to the nearest integer, minutes not
    /// zero-padded (e.g. `3:45`, `72:09`). Assumes a finite value; callers that
    /// can see non-finite / non-positive inputs guard before formatting.
    var asClock: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Duration as `h:mm:ss` when at least an hour, otherwise `m:ss`. Same
    /// rounding / padding rules as `asClock`; assumes a finite value.
    var asClockHMS: String {
        let total = Int(rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Duration as `mm:ss` with a zero-padded minutes field (the OLED clock
    /// style), or `00:00` for a non-finite value.
    var asClockPadded: String {
        guard isFinite else { return "00:00" }
        let t = Int(rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
