import Foundation

/// Health-checks the YouTube streaming pipeline (Playback ▸ Stream Engine ▸
/// Check YouTube Streaming…): asks yt-dlp for its version, then resolves a
/// known-stable public video through the exact `StreamResolver` path radio
/// playback uses. yt-dlp silently breaking after a YouTube change is the #1
/// way radio dies in the field — this gives the user a one-click diagnosis
/// and a repair action.
public struct StreamEngineDoctor: @unchecked Sendable {
    /// "Me at the zoo" — the first video ever uploaded to YouTube (2005). As
    /// stable as a public test URL gets; if yt-dlp can't resolve this, its
    /// YouTube extractor is broken, not the video.
    public static let testVideoURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    public enum Verdict: Equatable, Sendable {
        /// yt-dlp resolved the test video to a playable URL.
        case working(version: String)
        /// yt-dlp exists but could not resolve the test video.
        case broken(version: String, detail: String)
    }

    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner(timeoutSeconds: 60)) {
        self.runner = runner
    }

    public func checkUp(ytdlpURL: URL) -> Verdict {
        let version = (try? runner.run(executableURL: ytdlpURL, arguments: ["--version"]))
            .map { $0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"

        let probe = StreamSource(
            id: "stream-doctor", url: Self.testVideoURL, title: "", channel: "",
            kind: .video, hue: 0, addedAt: Date(timeIntervalSince1970: 0)
        )
        do {
            _ = try StreamResolver(ytdlpURL: ytdlpURL, runner: runner).resolve(probe)
            return .working(version: version)
        } catch StreamResolverError.commandFailed(let status, let stderr) {
            // yt-dlp prints "ERROR: <reason>" lines to stderr; the last
            // non-empty line is the most specific one.
            let lastLine = stderr
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            return .broken(version: version, detail: lastLine ?? "yt-dlp exited with status \(status)")
        } catch {
            return .broken(version: version, detail: String(describing: error))
        }
    }

    /// The command that updates the yt-dlp at `realToolPath` (symlinks already
    /// resolved by the caller). A Homebrew keg must be updated by brew — the
    /// binary's own `-U` refuses to touch package-manager installs; anything
    /// else self-updates with `-U`.
    public static func updateInvocation(
        realToolPath: String,
        brewPath: String?
    ) -> (executablePath: String, arguments: [String]) {
        if realToolPath.contains("/Cellar/"), let brewPath {
            return (brewPath, ["upgrade", "yt-dlp"])
        }
        return (realToolPath, ["-U"])
    }
}
