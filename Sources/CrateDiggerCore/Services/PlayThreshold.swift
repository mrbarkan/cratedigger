import Foundation

/// When a track counts as listened to.
///
/// One definition, shared by the Last.fm scrobbler and the play counter, so the
/// two can never drift apart and the rule is testable instead of inlined in a
/// view model. It is Last.fm's own guideline, which the app has used since
/// scrobbling shipped: half the track or four minutes, whichever comes first,
/// and never under thirty seconds.
///
/// `elapsed` is *accumulated listening time*, not playhead position. Seeking to
/// 90% and stopping is not a play, which is why the caller accumulates tick
/// deltas rather than reading the current time.
public enum PlayThreshold {

    /// Nothing shorter than this is a play, however short the track.
    public static let minimumSeconds: Double = 30

    /// Past this you have heard enough of anything, however long the track.
    public static let capSeconds: Double = 240

    /// The share of a track you have to hear for leaving it not to count as a
    /// skip. Short of 1.0 on purpose: `elapsed` is accumulated from playback
    /// ticks so it always lands a hair under the real duration, and the tail of
    /// a fade routinely goes missing while the next track loads. Four fifths is
    /// far enough in that no ordinary listen-through trips it, and far enough
    /// from the end that a genuine early abandon still reads as one.
    public static let heardOutFraction: Double = 0.8

    public static func isPlayed(elapsed: Double, duration: Double) -> Bool {
        guard duration > 0, elapsed > 0 else { return false }
        let trigger = min(duration / 2, capSeconds)
        return elapsed >= trigger && elapsed >= minimumSeconds
    }

    /// Whether leaving a track now counts as skipping it.
    ///
    /// Not simply the inverse of `isPlayed`. A track shorter than
    /// `minimumSeconds` can never satisfy the play rule, so treating "not
    /// played" as "skipped" would record a skip every time a short interlude
    /// runs to its end. Hearing a track out is never a skip, whatever its
    /// length.
    public static func isSkipped(elapsed: Double, duration: Double) -> Bool {
        guard duration > 0, elapsed > 0 else { return false }
        return elapsed < duration * heardOutFraction
    }
}
