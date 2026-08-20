import XCTest
@testable import CrateDiggerCore

final class StreamEngineDoctorTests: XCTestCase {
    /// Scripted runner: `--version` gets the version output, everything else
    /// (the resolve call) gets the probe output.
    private final class ScriptedRunner: CommandRunning {
        let version: CommandOutput
        let probe: CommandOutput
        init(version: CommandOutput, probe: CommandOutput) {
            self.version = version
            self.probe = probe
        }
        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
            arguments == ["--version"] ? version : probe
        }
    }

    private let ytdlp = URL(fileURLWithPath: "/bin/yt-dlp")

    private func out(_ status: Int32, stdout: String = "", stderr: String = "") -> CommandOutput {
        CommandOutput(terminationStatus: status, standardOutput: stdout, standardError: stderr)
    }

    func testWorkingWhenResolveSucceeds() {
        let runner = ScriptedRunner(
            version: out(0, stdout: "2026.06.09\n"),
            probe: out(0, stdout: "https://example.com/audio.m3u8\n")
        )
        let verdict = StreamEngineDoctor(runner: runner).checkUp(ytdlpURL: ytdlp)
        XCTAssertEqual(verdict, .working(version: "2026.06.09"))
    }

    func testBrokenSurfacesLastStderrLine() {
        let runner = ScriptedRunner(
            version: out(0, stdout: "2024.01.01\n"),
            probe: out(1, stderr: "WARNING: something\nERROR: unable to extract player response\n")
        )
        let verdict = StreamEngineDoctor(runner: runner).checkUp(ytdlpURL: ytdlp)
        XCTAssertEqual(verdict, .broken(version: "2024.01.01",
                                        detail: "ERROR: unable to extract player response"))
    }

    func testBrokenWithSilentFailureReportsExitStatus() {
        let runner = ScriptedRunner(version: out(0, stdout: "2024.01.01"), probe: out(2))
        let verdict = StreamEngineDoctor(runner: runner).checkUp(ytdlpURL: ytdlp)
        XCTAssertEqual(verdict, .broken(version: "2024.01.01",
                                        detail: "yt-dlp exited with status 2"))
    }

    func testHomebrewKegUpdatesViaBrew() {
        let (exe, args) = StreamEngineDoctor.updateInvocation(
            realToolPath: "/opt/homebrew/Cellar/yt-dlp/2026.6.9/bin/yt-dlp",
            brewPath: "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(exe, "/opt/homebrew/bin/brew")
        XCTAssertEqual(args, ["upgrade", "yt-dlp"])
    }

    func testStandaloneBinarySelfUpdates() {
        let (exe, args) = StreamEngineDoctor.updateInvocation(
            realToolPath: "/usr/local/bin/yt-dlp", brewPath: "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(exe, "/usr/local/bin/yt-dlp")
        XCTAssertEqual(args, ["-U"])
    }

    func testKegWithoutBrewFallsBackToSelfUpdate() {
        let (exe, args) = StreamEngineDoctor.updateInvocation(
            realToolPath: "/opt/homebrew/Cellar/yt-dlp/2026.6.9/bin/yt-dlp", brewPath: nil
        )
        XCTAssertEqual(exe, "/opt/homebrew/Cellar/yt-dlp/2026.6.9/bin/yt-dlp")
        XCTAssertEqual(args, ["-U"])
    }

    // MARK: - Update verification

    /// The bug this guards: `brew upgrade yt-dlp` exits 0 with nothing to do
    /// when the formula is already the newest brew has, so the app declared
    /// success over a six-week-old binary and streaming stayed broken.
    func testAnUnchangedVersionIsNotAnUpdate() {
        XCTAssertFalse(StreamEngineDoctor.versionChanged(from: "2026.07.04", to: "2026.07.04"))
    }

    func testAMovedVersionIsAnUpdate() {
        XCTAssertTrue(StreamEngineDoctor.versionChanged(from: "2026.07.04", to: "2026.08.19"))
    }

    /// If we couldn't read the version beforehand, a readable one afterwards is
    /// the best evidence available — treat it as progress rather than failing
    /// the user into a download they may not need.
    func testAnUnknownStartingPointCountsAsUpdatedOnceReadable() {
        XCTAssertTrue(StreamEngineDoctor.versionChanged(from: nil, to: "2026.08.19"))
        XCTAssertTrue(StreamEngineDoctor.versionChanged(from: "unknown", to: "2026.08.19"))
    }

    /// An unreadable result afterwards proves nothing, so it must not be sold
    /// as a successful update.
    func testAnUnreadableResultIsNeverAnUpdate() {
        for after in [nil, "", "unknown"] {
            XCTAssertFalse(StreamEngineDoctor.versionChanged(from: "2026.07.04", to: after),
                           "after=\(after ?? "nil")")
        }
    }

    func testStandaloneDestinationLivesUnderTheAppsOwnFolder() {
        let base = URL(fileURLWithPath: "/tmp/AppSupport")
        let destination = StreamEngineDoctor.standaloneDestination(applicationSupport: base)
        XCTAssertEqual(destination.path, "/tmp/AppSupport/CrateDigger/bin/yt-dlp")
    }

    /// Pinning the URL: "latest" has to stay latest, or this whole escape hatch
    /// silently becomes another stale install.
    func testStandaloneDownloadIsTheLatestRelease() {
        let url = StreamEngineDoctor.standaloneDownloadURL.absoluteString
        XCTAssertTrue(url.contains("/releases/latest/download/"), url)
        XCTAssertTrue(url.hasSuffix("yt-dlp_macos"), url)
    }
}
