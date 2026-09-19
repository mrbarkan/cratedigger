import Foundation

public struct StreamDownloadPlan: Equatable, Sendable {
    public let folder: URL
    public let baseName: String
    public var fileURL: URL { folder.appendingPathComponent(baseName).appendingPathExtension("m4a") }
}

public enum StreamDownloadError: Error, Equatable {
    /// Live streams never end and a playlist is many downloads.
    case notDownloadable(StreamKind)
    case commandFailed(Int32, String)
    /// yt-dlp exited 0 but the planned file is not there.
    case fileMissing
}

/// Saves a stream's audio for offline listening by running yt-dlp. The plan,
/// the argument vector and the progress parsing are pure; only `download` spawns.
public struct StreamDownloader: @unchecked Sendable {
    private let ytdlpURL: URL
    private let runner: StreamingCommandRunning

    public init(ytdlpURL: URL, runner: StreamingCommandRunning = ProcessStreamingCommandRunner()) {
        self.ytdlpURL = ytdlpURL
        self.runner = runner
    }

    /// `<root>/<Channel>/<Title>/<Title>.m4a`. One folder per download so its
    /// cover.jpg belongs to it alone.
    public static func plan(for stream: StreamSource, in root: URL) throws -> StreamDownloadPlan {
        guard stream.kind == .video || stream.kind == .mix else {
            throw StreamDownloadError.notDownloadable(stream.kind)
        }
        let channel = PathComponentSanitizer.sanitize(stream.channel, fallback: "Unknown Channel")
        let title = PathComponentSanitizer.sanitize(stream.title, fallback: stream.id)
        return StreamDownloadPlan(
            folder: root.appendingPathComponent(channel).appendingPathComponent(title),
            baseName: title)
    }

    /// Raw byte counts, not yt-dlp's formatted percent string, which carries
    /// colour codes and padding.
    static let progressTemplate =
        "download:CDPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"

    public static func arguments(for stream: StreamSource, plan: StreamDownloadPlan, ffmpegURL: URL?) -> [String] {
        // The file name is ours, so a % in a title must not read as a template field.
        let output = plan.folder.appendingPathComponent(plan.baseName).path
            .replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
        var args = [
            "-f", "bestaudio[ext=m4a]/bestaudio",   // AAC as YouTube made it; AVPlayer cannot play Opus
            "-x", "--audio-format", "m4a",          // only re-encodes when the m4a rung missed
            "--embed-metadata",
            "--no-playlist", "--no-overwrites",
            "--newline", "--progress-template", progressTemplate,
            "-o", output,
        ]
        if let ffmpegURL { args += ["--ffmpeg-location", ffmpegURL.path] }
        // "--" ends option parsing so a stored URL can never be read as a flag.
        return args + ["--", stream.url]
    }

    /// 0...1 from one progress-template line; nil for any other line.
    public static func progress(fromLine line: String) -> Double? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "CDPROGRESS", let done = Double(parts[1]) else { return nil }
        guard let total = Double(parts[2]) ?? Double(parts[3]), total > 0 else { return nil }
        return Swift.min(1, Swift.max(0, done / total))
    }

    @discardableResult
    public func download(_ stream: StreamSource,
                         plan: StreamDownloadPlan,
                         ffmpegURL: URL?,
                         onProgress: @escaping @Sendable (Double) -> Void,
                         completion: @escaping @Sendable (Result<URL, StreamDownloadError>) -> Void) throws -> StreamingCommandHandle {
        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        return try runner.start(
            executableURL: ytdlpURL,
            arguments: Self.arguments(for: stream, plan: plan, ffmpegURL: ffmpegURL),
            onLine: { line in if let p = Self.progress(fromLine: line) { onProgress(p) } },
            completion: { status, tail in
                guard status == 0 else { return completion(.failure(.commandFailed(status, tail))) }
                FileManager.default.fileExists(atPath: plan.fileURL.path)
                    ? completion(.success(plan.fileURL))
                    : completion(.failure(.fileMissing))
            })
    }
}
