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

    // MARK: - Updating

    /// yt-dlp's own notarised macOS build, always the newest release. The escape
    /// hatch when a package manager is behind: Homebrew's formula routinely lags
    /// yt-dlp by weeks, and YouTube breaks extractors faster than that.
    public static let standaloneDownloadURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    )!

    /// Where a directly-downloaded yt-dlp lives — beside the app's other state,
    /// so no package manager owns it and nothing else can overwrite it.
    public static func standaloneDestination(
        applicationSupport: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL {
        (applicationSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("CrateDigger", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    /// Did the update actually change anything?
    ///
    /// `brew upgrade yt-dlp` exits 0 whether it upgraded or found nothing to do,
    /// so exit status alone reported success while leaving a six-week-old binary
    /// in place — the user pressed the button, was congratulated, and streaming
    /// stayed broken. Only a moved version number counts.
    public static func versionChanged(from before: String?, to after: String?) -> Bool {
        guard let after, !after.isEmpty, after != "unknown" else { return false }
        guard let before, !before.isEmpty, before != "unknown" else { return true }
        return before != after
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
