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
