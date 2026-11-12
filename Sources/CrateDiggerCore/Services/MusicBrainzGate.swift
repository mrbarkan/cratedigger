import Foundation

/// The one gate every MusicBrainz request in the app waits at. MusicBrainz
/// allows anonymous clients about one request a second and answers 503 past
/// it, and the limit is per client, not per feature: artwork search, FIX
/// TAGS, DEEP SCAN, CD lookup, artist pictures and artist profiles all count
/// against the same budget, so they all share `shared`.
///
/// Two lanes. A foreground request (one the owner started) claims the next
/// free slot as soon as it arrives, as every request always did. A
/// background request (work the app does by itself, such as the artist
/// lookup worker) claims nothing while it waits: it is let through only when
/// its slot has come and no foreground request is waiting, so however many
/// background requests are queued, a foreground one is the next out. Both
/// lanes keep the one-per-`interval` spacing and obey `holdOff`; background
/// requests go in the order they arrived, and one that is cancelled leaves
/// the queue at once, its place taken by the next.
///
/// A foreground slot is claimed before sleeping: an actor is re-entrant
/// across the sleep, so a gate that recorded the time only afterwards would
/// let every caller that arrived during the wait read the same old time and
/// fire together.
public actor MusicBrainzGate {
    public static let shared = MusicBrainzGate(interval: .milliseconds(1_050))

    /// Who is asking: a lookup the owner started (`foreground`), or work the
    /// app does on its own in the background.
    public enum Lane: Sendable {
        case foreground, background
    }

    private let interval: Duration
    /// The first free slot: no request goes before it.
    private var next: ContinuousClock.Instant?
    /// Foreground requests that claimed a slot and have not reached it yet.
    private var foregroundWaiting = 0
    /// Background requests, oldest first.
    private var background: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextBackgroundID: UInt64 = 0
    /// Wakes the gate when the first free slot comes, for the background queue.
    private var timer: Task<Void, Never>?
    private var timerDeadline: ContinuousClock.Instant?
    /// Slots handed out per lane, for tests.
    private(set) var issued: [Lane: Int] = [:]

    /// Tests pass their own gate (`.zero`, or a short interval).
    public init(interval: Duration) {
        self.interval = interval
    }

    /// Returns when this caller's slot has come. Throws `CancellationError`
    /// when the caller is cancelled while it waits.
    public func wait(lane: Lane = .foreground) async throws {
        switch lane {
        case .foreground: try await waitInForeground()
        case .background: try await waitInBackground()
        }
    }

    /// Nobody's next request goes before `pause` from now (after a 503).
    public func holdOff(_ pause: Duration) {
        let until = ContinuousClock.now + pause
        next = max(next ?? until, until)
        releaseBackground()
    }

    // MARK: - Private

    private func waitInForeground() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next ?? now)
        next = slot + interval
        issued[.foreground, default: 0] += 1
        foregroundWaiting += 1
        defer {
            foregroundWaiting -= 1
            releaseBackground()
        }
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }

    private func waitInBackground() async throws {
        try Task.checkCancellation()
        let id = nextBackgroundID
        nextBackgroundID += 1
        // The queue entry is added before this job suspends, so a
        // cancellation (which hops back onto the actor) always finds it.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                background.append((id, continuation))
                releaseBackground()
            }
        } onCancel: {
            Task { await self.cancelBackground(id) }
        }
    }

    private func cancelBackground(_ id: UInt64) {
        guard let index = background.firstIndex(where: { $0.id == id }) else { return } // already let through
        background.remove(at: index).continuation.resume(throwing: CancellationError())
        releaseBackground()
    }

    /// Lets the oldest background requests through while their slot has come
    /// and no foreground request is waiting; otherwise wakes again at the
    /// first free slot. A foreground request that finishes waiting calls
    /// this, so a queue it held back moves on.
    private func releaseBackground() {
        while let head = background.first {
            guard foregroundWaiting == 0 else { return }
            let now = ContinuousClock.now
            if let next, next > now {
                wake(at: next)
                return
            }
            background.removeFirst()
            next = now + interval
            issued[.background, default: 0] += 1
            head.continuation.resume()
        }
    }

    private func wake(at deadline: ContinuousClock.Instant) {
        guard timerDeadline != deadline else { return }
        timer?.cancel()
        timerDeadline = deadline
        timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.timerFired(deadline)
        }
    }

    private func timerFired(_ deadline: ContinuousClock.Instant) {
        guard timerDeadline == deadline else { return }
        timer = nil
        timerDeadline = nil
        releaseBackground()
    }
}
