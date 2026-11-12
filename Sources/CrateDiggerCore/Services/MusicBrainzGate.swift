import Foundation

/// The one gate every MusicBrainz request in the app waits at. MusicBrainz
/// allows anonymous clients about one request a second and answers 503 past
/// it, and the limit is per client, not per feature: artwork search, FIX
/// TAGS, DEEP SCAN, CD lookup and artist pictures all count against the
/// same budget, so they all share `shared`.
///
/// The slot is claimed before sleeping: an actor is re-entrant across the
/// sleep, so a gate that recorded the time only afterwards would let every
/// caller that arrived during the wait read the same old time and fire together.
public actor MusicBrainzGate {
    public static let shared = MusicBrainzGate(interval: .milliseconds(1_050))

    private let interval: Duration
    private var next: ContinuousClock.Instant?

    /// Tests pass their own gate (`.zero`, or a short interval).
    public init(interval: Duration) {
        self.interval = interval
    }

    /// Returns when this caller's slot has come.
    public func wait() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next ?? now)
        next = slot + interval
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }

    /// Nobody's next request goes before `pause` from now (after a 503).
    public func holdOff(_ pause: Duration) {
        let until = ContinuousClock.now + pause
        next = max(next ?? until, until)
    }
}
