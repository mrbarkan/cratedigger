#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Exercises `ProcessStreamingCommandRunner` itself against a real spawned
/// process: the line buffer, the drain, and `terminate()`. `StreamDownloaderTests`
/// only covers the pure statics (`plan`/`arguments`/`progress`); this is the
/// runner's own coverage, which is where a real regression showed up in review
/// (a leaked readability handler, a lock held during a callback, and a drain
/// that could block on an orphaned grandchild).
final class StreamingCommandRunnerTests: XCTestCase {
    private func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// \r and \n both end a line, and a trailing chunk with no delimiter at all
    /// ("c") is still flushed once the process exits. Also pins that completion
    /// fires exactly once, with the real exit status: `expectation` over-fulfills
    /// (and fails the test) if `completion` were ever called twice.
    func testCROrLFEndsALineAndTheUnterminatedTailIsFlushedOnExit() throws {
        let runner = ProcessStreamingCommandRunner()
        let lock = NSLock()
        var lines: [String] = []
        let exp = expectation(description: "completion")
        var lastStatus: Int32?
        let fdCountBefore = openFileDescriptorCount()

        _ = try runner.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\rb\\nc'; exit 3"],
            onLine: { line in
                lock.lock(); lines.append(line); lock.unlock()
            },
            completion: { status, _ in
                lock.lock(); lastStatus = status; lock.unlock()
                exp.fulfill()
            })

        wait(for: [exp], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(lines, ["a", "b", "c"])
        XCTAssertEqual(lastStatus, 3)
        // The success path (not just the throwing path) must also close the
        // read end, or every completed download leaks one fd.
        XCTAssertEqual(openFileDescriptorCount(), fdCountBefore)
    }

    /// A `run()` failure (nonexistent executable) must throw rather than spawn,
    /// and must not leave the standard pipe's file descriptors open. The old bug
    /// left the readability handler armed after the throw: with nothing left to
    /// close the write end, the pipe hit EOF and the handler re-fired forever,
    /// spinning a background thread and never releasing either fd.
    func testFailedRunThrowsAndDoesNotLeakTheStandardPipe() throws {
        let runner = ProcessStreamingCommandRunner()
        let before = openFileDescriptorCount()
        for i in 0..<10 {
            let bogus = URL(fileURLWithPath: "/nonexistent/definitely-not-here-\(i)-\(UUID().uuidString)")
            XCTAssertThrowsError(try runner.start(executableURL: bogus, arguments: [], onLine: { _ in }, completion: { _, _ in }))
        }
        XCTAssertEqual(openFileDescriptorCount(), before)
    }

    /// A yt-dlp postprocessing step (ffmpeg) is a grandchild that inherits the
    /// shared pipe and can outlive yt-dlp once yt-dlp is signalled. `terminate()`
    /// must not block on that orphan.
    ///
    /// `Process` puts its child in its own process group and `terminate()`
    /// signals that whole group, so a plain `sh -c "sleep N & sleep 30"` is not
    /// enough: the backgrounded job shares the shell's group and dies with it,
    /// which means the pre-fix drain also returns instantly and the test would
    /// pass for the wrong reason (verified: it did, in an earlier version of
    /// this test). `set -m` (job control) is what makes the backgrounded job a
    /// *genuine* orphan: it gets its own process group, so `terminate()`'s
    /// group signal to the shell's group never reaches it, and it survives to
    /// prove the fix is doing real work.
    func testTerminateDoesNotBlockOnAJobControlOrphanedGrandchild() throws {
        let runner = ProcessStreamingCommandRunner()
        let exp = expectation(description: "completion")
        let handle = try runner.start(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "set -m; sleep 9 & sleep 30"],
            onLine: { _ in },
            completion: { _, _ in exp.fulfill() })

        Thread.sleep(forTimeInterval: 0.2)   // let bash launch and background the job
        let cancelledAt = Date()
        handle.terminate()
        wait(for: [exp], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1,
                          "terminate() should not wait for the orphaned grandchild")

        // Confirm the orphan is genuinely still alive (not incidentally also
        // killed), so a fast completion here actually proves something.
        XCTAssertTrue(processExists(commandContaining: "sleep 9"),
                      "the orphan should have survived terminate() -- if it didn't, this test proves nothing")
        killAll(commandContaining: "sleep 9")
    }

    private func processExists(commandContaining needle: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", needle]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        return !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
    }

    private func killAll(commandContaining needle: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", needle]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
#endif
