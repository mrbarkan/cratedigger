import Foundation

/// A playable URL for a stream, resolved by yt-dlp. For live, this is typically
/// an HLS (`.m3u8`) manifest; for VOD, an m4a/AAC progressive URL (both of which
/// AVPlayer can decode — unlike YouTube's default WebM/Opus).
public struct ResolvedStream: Sendable, Equatable {
    public let playbackURL: URL
    public let isLive: Bool
    public let durationSeconds: Double?

    public init(playbackURL: URL, isLive: Bool, durationSeconds: Double? = nil) {
        self.playbackURL = playbackURL
        self.isLive = isLive
        self.durationSeconds = durationSeconds
    }
}

public enum StreamResolverError: Error, Equatable {
    case emptyOutput
    case commandFailed(Int32, String)
    case badURL(String)
}

/// Resolves a `StreamSource` to a playable URL by invoking yt-dlp. The argument
/// vector and format selection are pure (and unit-tested with a fake
/// `CommandRunning`); only `resolve` actually spawns the process.
///
/// `@unchecked Sendable`: the only non-Sendable member is the injected
/// `CommandRunning`; in production that's `ProcessCommandRunner` (a stateless
/// value type, safe to use from a background task). This lets `resolve` run
/// off the main actor.
public struct StreamResolver: @unchecked Sendable {
    private let ytdlpURL: URL
    private let runner: CommandRunning

    public init(ytdlpURL: URL, runner: CommandRunning = ProcessCommandRunner()) {
        self.ytdlpURL = ytdlpURL
        self.runner = runner
    }

    /// The yt-dlp argument vector for this stream. AVPlayer can't decode WebM/Opus,
    /// so VOD prefers m4a/AAC; live takes best audio (YouTube live is HLS/AAC).
    public func arguments(for stream: StreamSource) -> [String] {
        let vodFormat = "ba[ext=m4a]/bestaudio[acodec^=mp4a]/best"
        switch stream.kind {
        case .live:
            return ["-g", "-f", "bestaudio/best", "--no-playlist", stream.url]
        case .video, .mix:
            return ["-g", "-f", vodFormat, "--no-playlist", stream.url]
        case .playlist:
            return ["-g", "-f", vodFormat, "--yes-playlist", "--playlist-items", "1", stream.url]
        }
    }

    public func resolve(_ stream: StreamSource) throws -> ResolvedStream {
        let output = try runner.run(executableURL: ytdlpURL, arguments: arguments(for: stream))
        guard output.terminationStatus == 0 else {
            throw StreamResolverError.commandFailed(output.terminationStatus, output.standardError)
        }
        let firstURL = output.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line = firstURL else { throw StreamResolverError.emptyOutput }
        guard let url = URL(string: line) else { throw StreamResolverError.badURL(line) }
        return ResolvedStream(playbackURL: url, isLive: stream.isLive, durationSeconds: stream.durationSeconds)
    }
}
