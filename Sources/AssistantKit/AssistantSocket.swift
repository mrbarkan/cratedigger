import Foundation

/// One tool call as the helper hands it to the running app: the tool and its
/// arguments, nothing of the JSON-RPC around it (the helper answers that).
public struct AssistantCall: Codable, Sendable, Equatable {
    public var tool: String
    public var arguments: [String: JSONValue]

    public init(tool: String, arguments: [String: JSONValue]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public enum AssistantSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case system(String, Int32)
    case alreadyServed(String)
    case closed
    case badReply

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): return "The assistant's socket path is too long for macOS: \(path)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .alreadyServed(let path): return "Another CrateDigger is already serving the assistant at \(path)"
        case .closed: return "CrateDigger closed the connection"
        case .badReply: return "CrateDigger sent a reply that could not be read"
        }
    }
}

/// Where the app listens and the helper connects: one unix-domain socket in
/// the user's own Application Support folder. No port, so nothing on the
/// network can reach it, and created 0600, so no other user can either.
public enum AssistantSocket {
    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CrateDigger/assistant.sock").path
    }

    /// `sun_path` holds 104 bytes including the terminator.
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw AssistantSocketError.pathTooLong(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AssistantSocketError.system("socket", errno) }
        // A peer that hangs up mid-write must cost an EPIPE, not the process.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(to path: String, timeout: TimeInterval?) throws -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        if let timeout {
            var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw AssistantSocketError.system("connect", code)
        }
        return fd
    }

    /// Writes all of `data`, across partial writes.
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AssistantSocketError.system("write", errno)
                }
                offset += written
            }
        }
    }
}

/// Reads newline-terminated lines from a file descriptor.
struct LineReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline, or nil at end of stream.
    mutating func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AssistantSocketError.system("read", errno)
            }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// The app's end: accepts the helper's connections and answers each line with
/// one line. Each connection gets its own thread, and each call waits for the
/// handler there, so a slow call never holds up the accept loop.
public final class AssistantSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AssistantCall) async -> MCPToolResult

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: Set<Int32> = []

    public init(path: String = AssistantSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener >= 0
    }

    public func start() throws {
        guard !isRunning else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // A socket file left by a crash answers nothing and can be replaced;
        // one that answers belongs to another running copy, which keeps it.
        if FileManager.default.fileExists(atPath: path) {
            if let fd = try? AssistantSocket.connect(to: path, timeout: 1) {
                close(fd)
                throw AssistantSocketError.alreadyServed(path)
            }
            unlink(path)
        }

        var address = try AssistantSocket.address(for: path)
        let fd = try AssistantSocket.makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw AssistantSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw AssistantSocketError.system("listen", code)
        }

        lock.lock(); listener = fd; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "CrateDigger assistant socket"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        let open = connections
        connections.removeAll()
        lock.unlock()
        guard fd >= 0 else { return }
        // Closing the listener is what wakes the blocked accept().
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for connection in open { shutdown(connection, SHUT_RDWR) }
        unlink(path)
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return   // the listener was closed by stop()
            }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            guard listener == fd else { lock.unlock(); close(connection); return }
            connections.insert(connection)
            lock.unlock()
            let thread = Thread { [weak self] in self?.serve(connection) }
            thread.name = "CrateDigger assistant connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock(); connections.remove(fd); lock.unlock()
            close(fd)
        }
        var reader = LineReader(fd: fd)
        while let line = try? reader.next() {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
            let result: MCPToolResult
            if let call = try? JSONDecoder().decode(AssistantCall.self, from: line) {
                result = wait(for: call)
            } else {
                result = .failure("CrateDigger could not read that request.")
            }
            guard var reply = try? JSONEncoder().encode(result) else { return }
            reply.append(0x0A)
            do { try AssistantSocket.writeAll(reply, to: fd) } catch { return }
        }
    }

    /// Runs the async handler and blocks this (dedicated, non-pool) thread
    /// until it answers. The handler hops to the main actor; blocking here
    /// never ties up a thread that work could be waiting on.
    private func wait(for call: AssistantCall) -> MCPToolResult {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task.detached {
            box.set(await handler(call))
            done.signal()
        }
        done.wait()
        return box.value ?? .failure("CrateDigger did not answer.")
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MCPToolResult?
        func set(_ value: MCPToolResult) { lock.lock(); stored = value; lock.unlock() }
        var value: MCPToolResult? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

/// The helper's end: one connection to the app, opened when first needed and
/// reopened once if the app restarted in between.
public final class AssistantSocketClient: @unchecked Sendable {
    public let path: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var reader: LineReader?

    /// The app answers quickly, but a call that rebuilds a big crate or waits
    /// on the main thread behind a long redraw can take seconds, so the limit
    /// is generous; it only exists so a hung app can't hang Claude forever.
    public init(path: String = AssistantSocket.defaultPath, timeout: TimeInterval = 120) {
        self.path = path
        self.timeout = timeout
    }

    deinit { disconnect() }

    /// One call at a time: replies come back in order on the one connection.
    public func call(_ call: AssistantCall) throws -> MCPToolResult {
        lock.lock(); defer { lock.unlock() }
        var line = try JSONEncoder().encode(call)
        line.append(0x0A)
        let reused = fd >= 0
        if !reused { try connect() }
        do {
            try AssistantSocket.writeAll(line, to: fd)
        } catch where reused {
            // The connection outlived the app it was made to. Nothing reached
            // the new one yet, so sending again cannot apply anything twice.
            disconnect()
            try connect()
            try AssistantSocket.writeAll(line, to: fd)
        }
        // A failure after the write is not retried: the app may have acted.
        guard let reply = try reader?.next() else {
            disconnect()
            throw AssistantSocketError.closed
        }
        guard let result = try? JSONDecoder().decode(MCPToolResult.self, from: reply) else {
            throw AssistantSocketError.badReply
        }
        return result
    }

    private func connect() throws {
        fd = try AssistantSocket.connect(to: path, timeout: timeout)
        reader = LineReader(fd: fd)
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        reader = nil
    }
}
