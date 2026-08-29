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

    public static func isPlayed(elapsed: Double, duration: Double) -> Bool {
        guard duration > 0, elapsed > 0 else { return false }
        let trigger = min(duration / 2, capSeconds)
        return elapsed >= trigger && elapsed >= minimumSeconds
    }
}
