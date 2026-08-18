import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// A playback failure on a freshly-resolved YouTube URL is usually googlevideo
/// 403ing a good URL, so the engine re-resolves once. These pin the "once" —
/// no retry at all loses playable streams, and an unbounded retry spawns
/// yt-dlp forever on a genuinely dead one.
@MainActor
final class YtDlpStreamEngineRetryTests: XCTestCase {

    private func makeEngine() -> (YtDlpStreamEngine, CountingRunner, FakePlayer) {
        let runner = CountingRunner()
        let player = FakePlayer()
        let resolver = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        return (YtDlpStreamEngine(resolver: resolver, player: player), runner, player)
    }

    private var stream: StreamSource {
        StreamSource(id: "s1", url: "https://www.youtube.com/watch?v=abc",
                     title: "T", channel: "C", kind: .video, hue: 0, addedAt: Date())
    }

    /// The engine resolves off the main actor, so let its task land.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testFirstPlaybackFailureReResolvesInsteadOfFailing() async {
        let (engine, runner, player) = makeEngine()
        var states: [RadioEngineState] = []
        engine.onStateChange = { states.append($0) }

        engine.play(stream)
        await settle()
        XCTAssertEqual(runner.runCount, 1)

        player.onError?("HTTP 403")
        await settle()

        XCTAssertEqual(runner.runCount, 2, "a first failure should re-resolve")
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } },
                       "the user should not see a failure while a retry is pending")
    }

    func testSecondPlaybackFailureSurfacesToTheUser() async {
        let (engine, runner, player) = makeEngine()
        var states: [RadioEngineState] = []
        engine.onStateChange = { states.append($0) }

        engine.play(stream)
        await settle()
        player.onError?("HTTP 403")
        await settle()
        player.onError?("HTTP 403")
        await settle()

        XCTAssertEqual(runner.runCount, 2, "the retry budget is one re-resolve per play")
        XCTAssertTrue(states.contains { if case .failed = $0 { return true } else { return false } },
                      "a second failure is real and must reach the UI")
    }

    func testFailureAfterStopDoesNotResurrectTheStream() async {
        let (engine, runner, player) = makeEngine()
        engine.play(stream)
        await settle()
        engine.stop()

        player.onError?("HTTP 403")
        await settle()

        XCTAssertEqual(runner.runCount, 1, "a stopped stream must not re-resolve")
    }

    func testPlayResetsTheRetryBudget() async {
        let (engine, runner, player) = makeEngine()
        engine.play(stream)
        await settle()
        player.onError?("HTTP 403")
        await settle()          // budget spent: 2 resolves

        engine.play(stream)     // a fresh play earns a fresh retry
        await settle()
        player.onError?("HTTP 403")
        await settle()

        XCTAssertEqual(runner.runCount, 4)
    }
}

// MARK: - Doubles

private final class CountingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        lock.lock(); count += 1; lock.unlock()
        return CommandOutput(terminationStatus: 0,
                             standardOutput: "https://rr1.googlevideo.com/videoplayback?itag=140\n",
                             standardError: "")
    }
}

/// Inert stand-in for `PlaybackService` — the engine only needs somewhere to
/// hand items and a hook to fire failures from.
private final class FakePlayer: PlaybackServiceProtocol {
    var state: PlaybackState = .idle
    var currentIndex: Int?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    var errorMessage: String?
    var queue: [PlaybackQueueItem] = []
    var repeatMode: PlaybackRepeatMode = .off
    var dsdOutputMode: DSDOutputMode = .auto
    var isNativeDSDActive = false

    var onStateChange: ((PlaybackState) -> Void)?
    var onCurrentIndexChange: ((Int?) -> Void)?
    var onTimeChange: ((Double, Double) -> Void)?
    var onError: ((String) -> Void)?

    func load(queue: [PlaybackQueueItem], startIndex: Int, autoPlay: Bool) { self.queue = queue }
    func insertNext(_ items: [PlaybackQueueItem]) -> Range<Int> { 0..<0 }
    func appendLast(_ items: [PlaybackQueueItem]) -> Range<Int> { 0..<0 }
    func removeFromQueue(at offsets: IndexSet) -> IndexSet { [] }
    func moveInQueue(from source: Int, to destination: Int) {}
    var upNext: ArraySlice<PlaybackQueueItem> { queue[0..<0] }
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(toSeconds: Double) {}
    func next() {}
    func previous() {}
    func setVolume(_ volume: Double) {}
    func setOutputDeviceUID(_ uid: String?) {}
    func currentLevels() -> (left: Double, right: Double) { (0, 0) }
    func currentSpectrum() -> [Double] { [] }
    func setEqualizer(enabled: Bool, gains: [Double]) {}
    func setMasterGain(_ gain: Double) {}
}
