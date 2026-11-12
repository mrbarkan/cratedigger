import XCTest
@testable import CrateDiggerCore

/// The shared MusicBrainz gate's two lanes: work the app does by itself
/// (background) never makes a lookup the owner started (foreground) wait.
/// A 60 ms gate; times are measured when each waiter resumes, so the
/// assertions leave room for scheduling.
final class MusicBrainzGateTests: XCTestCase {
    static let interval = Duration.milliseconds(60)

    /// The order waiters were let through, and when.
    private actor Log {
        private(set) var entries: [(label: String, at: ContinuousClock.Instant)] = []
        func note(_ label: String) { entries.append((label, .now)) }
        var labels: [String] { entries.map(\.label) }
    }

    private func pass(_ gate: MusicBrainzGate, _ lane: MusicBrainzGate.Lane, _ label: String, _ log: Log) -> Task<Void, Error> {
        Task {
            try await gate.wait(lane: lane)
            await log.note(label)
        }
    }

    /// Lets the tasks just started reach the gate.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(15))
    }

    /// Review focus 3: a 2,000-artist background run is queued while the
    /// owner runs FIX TAGS; the owner's request is the next one out.
    func testForegroundOvertakesQueuedBackground() async throws {
        let gate = MusicBrainzGate(interval: Self.interval)
        let log = Log()
        try await gate.wait() // the slot now taken: everyone else waits
        let background = (1...20).map { pass(gate, .background, "b\($0)", log) }
        try await settle()

        let start = ContinuousClock.now
        try await pass(gate, .foreground, "f", log).value
        let waited = ContinuousClock.now - start
        XCTAssertLessThan(waited, Self.interval * 2, "the foreground request waited behind the background queue")

        for task in background { task.cancel() }
        let labels = await log.labels
        XCTAssertEqual(labels.first, "f")
        XCTAssertEqual(labels, ["f"], "no background request went before it")
    }

    func testBackgroundRunsWhenNoForegroundWaits() async throws {
        let gate = MusicBrainzGate(interval: Self.interval)
        let log = Log()
        let start = ContinuousClock.now
        try await gate.wait(lane: .background)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(40), "an idle gate lets background through at once")

        let tasks = (1...3).map { pass(gate, .background, "b\($0)", log) }
        for task in tasks { try await task.value }
        let entries = await log.entries
        XCTAssertEqual(entries.map(\.label).sorted(), ["b1", "b2", "b3"])
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, Self.interval * 3 - .milliseconds(20))
        let issued = await gate.issued
        XCTAssertEqual(issued, [.background: 4])
    }

    func testSpacingHoldsAcrossLanes() async throws {
        let gate = MusicBrainzGate(interval: Self.interval)
        let log = Log()
        let tasks = [pass(gate, .background, "b1", log), pass(gate, .foreground, "f1", log),
                     pass(gate, .background, "b2", log), pass(gate, .foreground, "f2", log),
                     pass(gate, .background, "b3", log)]
        for task in tasks { try await task.value }
        let times = await log.entries.map(\.at).sorted()
        XCTAssertEqual(times.count, 5)
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, .milliseconds(35))
        }
        if let first = times.first, let last = times.last {
            XCTAssertGreaterThanOrEqual(last - first, Self.interval * 4 - .milliseconds(20))
        }

        // A hold-off after a 503 holds the background lane as well.
        let held = ContinuousClock.now
        await gate.holdOff(.milliseconds(150))
        try await gate.wait(lane: .background)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - held, .milliseconds(140))
    }

    func testCancelledBackgroundWaiterFreesItsPlace() async throws {
        let gate = MusicBrainzGate(interval: Self.interval)
        let log = Log()
        let start = ContinuousClock.now
        try await gate.wait()
        let first = pass(gate, .background, "b1", log)
        try await settle()
        let second = pass(gate, .background, "b2", log)
        try await settle()
        first.cancel()
        do {
            try await first.value
            XCTFail("a cancelled waiter throws")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await second.value
        // b2 went in b1's slot (one interval after the first), not a slot later.
        XCTAssertLessThan(ContinuousClock.now - start, Self.interval * 2 - .milliseconds(10))
        let labels = await log.labels
        XCTAssertEqual(labels, ["b2"])

        // A waiter cancelled before it ever reaches the gate takes no slot.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.wait(lane: .background)
        }
        do {
            try await early.value
            XCTFail("an already cancelled waiter throws")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let issued = await gate.issued
        XCTAssertEqual(issued, [.foreground: 1, .background: 1])
    }

    /// Every caller from before the lanes (FIX TAGS, artwork search, DEEP
    /// SCAN, CD lookup) calls `wait()`, which is the foreground lane.
    func testExistingWaitIsForeground() async throws {
        let gate = MusicBrainzGate(interval: Self.interval)
        let log = Log()
        try await gate.wait()
        let background = pass(gate, .background, "b", log)
        try await settle()
        try await gate.wait()
        await log.note("plain wait()")
        try await background.value
        let labels = await log.labels
        XCTAssertEqual(labels, ["plain wait()", "b"])
        let issued = await gate.issued
        XCTAssertEqual(issued, [.foreground: 2, .background: 1])
    }
}
