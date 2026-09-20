import Foundation

public protocol StreamingCommandHandle: Sendable {
    /// Kill the process. Its completion still fires, with a non-zero status.
    func terminate()
}

/// Like `CommandRunning`, for a tool whose output is wanted while it runs.
/// `CommandRunning` reads to end of file, so it can neither report progress nor
/// be stopped; a download needs both.
public protocol StreamingCommandRunning: Sendable {
    func start(executableURL: URL,
               arguments: [String],
               onLine: @escaping @Sendable (String) -> Void,
               completion: @escaping @Sendable (_ status: Int32, _ errorTail: String) -> Void) throws -> StreamingCommandHandle
}

public struct ProcessStreamingCommandRunner: StreamingCommandRunning {
    public init() {}

    /// Safe from any thread: `Process.terminate()`/`.isRunning` are documented
    /// thread-safe. The shared `pipe`'s `FileHandle` is touched from both
    /// `terminate()` and the termination handler (`readabilityHandler = nil`
    /// and `close()` appear on both paths), which is safe because Foundation
    /// defers the actual `close(2)` until the readability source's
    /// cancellation has completed, so an in-flight read can never observe a
    /// closed fd, and a second `close()` on an already-closed handle returns
    /// normally rather than throwing or raising.
    private final class Handle: StreamingCommandHandle, @unchecked Sendable {
        let process: Process
        private let pipe: Pipe
        private let lock = NSLock()
        private var handledTermination = false

        init(_ process: Process, pipe: Pipe) {
            self.process = process
            self.pipe = pipe
        }

        func terminate() {
            if claim() {
                // yt-dlp's postprocessing step (ffmpeg, run via -x) is a grandchild
                // that inherits the pipe's write end and can outlive yt-dlp itself.
                // Left alone, the termination handler's drain would block on that
                // orphan until its re-encode finishes, so Cancel would hang. Closing
                // our read end here makes that drain a no-op instead.
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
            if process.isRunning { process.terminate() }
        }

        /// One-shot gate shared with the termination handler: whichever of
        /// `terminate()` / the handler calls this first (true) owns the pipe's
        /// end-of-stream handling; the other (false) skips it.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !handledTermination else { return false }
            handledTermination = true
            return true
        }
    }

    /// Splits a byte stream into lines and remembers the last few for error reports.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var tail: [String] = []

        /// Collects newly completed lines under the lock, then calls `emit` for
        /// each after releasing it, so a caller that hops threads or reaches back
        /// into this buffer (e.g. for `errorTail`) from `emit` cannot deadlock.
        func feed(_ data: Data, emit: (String) -> Void) {
            var completedLines: [String] = []
            lock.lock()
            pending.append(data)
            // yt-dlp redraws progress with \r when --newline is missing; treat both as ends of line.
            while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...i)
                guard !line.isEmpty else { continue }
                tail.append(line); if tail.count > 12 { tail.removeFirst() }
                completedLines.append(line)
            }
            lock.unlock()
            completedLines.forEach(emit)
        }

        /// Emits whatever's left in `pending` as one final line. yt-dlp's last
        /// progress update, and often its very last line of output, never gets a
        /// trailing delimiter, so without this the tail is silently dropped:
        /// measured empirically, the readability handler's `availableData` call
        /// reliably wins the race to drain the pipe before the termination
        /// handler's own read runs, so that read alone sees nothing left to flush.
        /// Idempotent: a second call after `pending` was already drained emits
        /// nothing.
        func flushRemainder(emit: (String) -> Void) {
            var finalLine: String?
            lock.lock()
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                pending.removeAll()
                if !line.isEmpty {
                    tail.append(line); if tail.count > 12 { tail.removeFirst() }
                    finalLine = line
                }
            }
            lock.unlock()
            if let finalLine { emit(finalLine) }
        }
        var errorTail: String { lock.lock(); defer { lock.unlock() }; return tail.joined(separator: "\n") }
    }

    public func start(executableURL: URL,
                      arguments: [String],
                      onLine: @escaping @Sendable (String) -> Void,
                      completion: @escaping @Sendable (Int32, String) -> Void) throws -> StreamingCommandHandle {
        // Same guard as ProcessCommandRunner: an embedded NUL raises an ObjC
        // exception Swift cannot catch.
        if let offending = ([executableURL.path] + arguments).first(where: { $0.utf8.contains(0) }) {
            throw ConversionServiceError.unrepresentableArgument(offending)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessCommandRunner.augmentedPATH(env["PATH"])   // yt-dlp needs deno/node and ffmpeg
        process.environment = env

        let pipe = Pipe()   // stdout and stderr together: yt-dlp's progress stream varies by mode
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        let handle = Handle(process, pipe: pipe)

        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            buffer.feed(data, emit: onLine)
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            if handle.claim() {
                // Nobody closed the pipe ahead of us (the ordinary, non-cancelled
                // path): pick up any bytes the readability handler hasn't gotten to
                // yet (a single bounded read; unreachable in our one caller because
                // yt-dlp already waits for its own postprocessing child before
                // exiting, not a guarantee this code itself makes), then flush
                // whatever's left as a final unterminated line.
                let rest = pipe.fileHandleForReading.availableData
                if !rest.isEmpty { buffer.feed(rest, emit: onLine) }
                buffer.flushRemainder(emit: onLine)
            }
            // Closes the read end exactly once in practice: `terminate()` already
            // closed it in the cancelled path (this is then a harmless no-op), and
            // this is the only place that closes it otherwise. Without it the fd
            // is never released, leaking one per download for the app's lifetime.
            try? pipe.fileHandleForReading.close()
            completion(finished.terminationStatus, buffer.errorTail)
        }
        do {
            try process.run()
        } catch {
            // `run()` throwing (yt-dlp missing, not executable, quarantined) means
            // the process never started, so nothing will ever close this pipe and
            // fire the handlers above; leaving the readability handler installed
            // spins forever on repeated EOF reads, and the fds stay open forever.
            // No child was ever spawned to receive the write end either, so unlike
            // the launched-and-exited path, we own both ends here.
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
        return handle
    }
}
