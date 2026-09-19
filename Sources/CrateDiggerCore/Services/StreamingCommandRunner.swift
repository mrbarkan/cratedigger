import Foundation

public protocol StreamingCommandHandle: Sendable {
    /// Kill the process. Its completion still fires, with a non-zero status.
    func terminate()
}

/// Like `CommandRunning`, for a tool whose output is wanted while it runs.
/// `CommandRunning` reads to end of file, so it can neither report progress nor
/// be stopped; a download needs both.
public protocol StreamingCommandRunning {
    func start(executableURL: URL,
               arguments: [String],
               onLine: @escaping @Sendable (String) -> Void,
               completion: @escaping @Sendable (_ status: Int32, _ errorTail: String) -> Void) throws -> StreamingCommandHandle
}

public struct ProcessStreamingCommandRunner: StreamingCommandRunning {
    public init() {}

    private final class Handle: StreamingCommandHandle, @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    /// Splits a byte stream into lines and remembers the last few for error reports.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var tail: [String] = []

        func feed(_ data: Data, emit: (String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            // yt-dlp redraws progress with \r when --newline is missing; treat both as ends of line.
            while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...i)
                guard !line.isEmpty else { continue }
                tail.append(line); if tail.count > 12 { tail.removeFirst() }
                emit(line)
            }
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
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.feed(data, emit: onLine)
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { buffer.feed(rest + Data([0x0A]), emit: onLine) }
            completion(finished.terminationStatus, buffer.errorTail)
        }
        try process.run()
        return Handle(process)
    }
}
