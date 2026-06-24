import XCTest
@testable import CrateDiggerCore

final class YtDlpLocatorTests: XCTestCase {
    func testYtDlpEnvOverrideResolvesAndUsesHyphenName() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exe = dir + "/yt-dlp"
        fm.createFile(atPath: exe, contents: Data())
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)

        let locator = ExternalToolLocator(
            environment: ["CRATEDIGGER_YTDLP_PATH": exe],
            bundle: .main,
            defaultSystemSearchDirectories: []
        )
        XCTAssertEqual(ExternalTool.ytdlp.executableName, "yt-dlp")
        XCTAssertEqual(locator.resolveOptional(.ytdlp)?.url.path, exe)
    }
}

final class StreamResolverTests: XCTestCase {
    final class FakeRunner: CommandRunning {
        var output: CommandOutput
        private(set) var lastArgs: [String] = []
        init(_ o: CommandOutput) { output = o }
        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
            lastArgs = arguments
            return output
        }
    }

    private let ytdlp = URL(fileURLWithPath: "/bin/yt-dlp")

    private func stream(_ kind: StreamKind) -> StreamSource {
        StreamSource(id: "1", url: "https://youtu.be/x", title: "t", channel: "c",
                     kind: kind, hue: 1, addedAt: Date())
    }

    private func ok(_ stdout: String) -> CommandOutput {
        CommandOutput(terminationStatus: 0, standardOutput: stdout, standardError: "")
    }

    func testLiveArgs() {
        let r = StreamResolver(ytdlpURL: ytdlp, runner: FakeRunner(ok("")))
        XCTAssertEqual(r.arguments(for: stream(.live)),
                       ["-g", "-f", "bestaudio/best", "--no-playlist", "https://youtu.be/x"])
    }

    func testVodArgsPreferM4A() {
        let r = StreamResolver(ytdlpURL: ytdlp, runner: FakeRunner(ok("")))
        let args = r.arguments(for: stream(.video))
        XCTAssertTrue(args.contains("ba[ext=m4a]/bestaudio[acodec^=mp4a]/best"))
        XCTAssertTrue(args.contains("--no-playlist"))
    }

    func testPlaylistArgsTakeFirstItem() {
        let r = StreamResolver(ytdlpURL: ytdlp, runner: FakeRunner(ok("")))
        let args = r.arguments(for: stream(.playlist))
        XCTAssertTrue(args.contains("--yes-playlist"))
        XCTAssertEqual(args[args.firstIndex(of: "--playlist-items").map { $0 + 1 } ?? 0], "1")
    }

    func testResolveReturnsFirstNonEmptyURL() throws {
        let runner = FakeRunner(ok("\nhttps://cdn/audio.m4a\nhttps://cdn/video.mp4\n"))
        let r = StreamResolver(ytdlpURL: ytdlp, runner: runner)
        let resolved = try r.resolve(stream(.video))
        XCTAssertEqual(resolved.playbackURL, URL(string: "https://cdn/audio.m4a"))
        XCTAssertFalse(resolved.isLive)
    }

    func testResolveLiveFlag() throws {
        let r = StreamResolver(ytdlpURL: ytdlp, runner: FakeRunner(ok("https://cdn/live.m3u8\n")))
        XCTAssertTrue(try r.resolve(stream(.live)).isLive)
    }

    func testResolveEmptyThrows() {
        let r = StreamResolver(ytdlpURL: ytdlp, runner: FakeRunner(ok("   \n")))
        XCTAssertThrowsError(try r.resolve(stream(.video))) { error in
            XCTAssertEqual(error as? StreamResolverError, .emptyOutput)
        }
    }

    func testResolveNonZeroThrows() {
        let runner = FakeRunner(CommandOutput(terminationStatus: 1, standardOutput: "", standardError: "ERROR: Video unavailable"))
        let r = StreamResolver(ytdlpURL: ytdlp, runner: runner)
        XCTAssertThrowsError(try r.resolve(stream(.video)))
    }
}
