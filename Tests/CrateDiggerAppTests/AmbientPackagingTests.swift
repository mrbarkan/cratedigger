import XCTest

/// Ambient needs two things the build can't check for itself.
///
/// Both failures are silent: without the usage string macOS never asks, and
/// without the entitlement a hardened-runtime (notarized) build is handed
/// buffers of zeros. The feature would ship, turn on, light its lamp, and play
/// nothing, and a `swift build` run would never show it.
final class AmbientPackagingTests: XCTestCase {

    private func packagingFile(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CrateDiggerAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Packaging/CrateDiggerApp")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testInfoPlistExplainsWhyTheMicrophoneIsNeeded() throws {
        let plist = try packagingFile("Info.plist")
        XCTAssertTrue(plist.contains("<key>NSMicrophoneUsageDescription</key>"),
                      "Info.plist lost NSMicrophoneUsageDescription; macOS will never ask for the mic")
    }

    func testEntitlementsAllowAudioInput() throws {
        let entitlements = try packagingFile("CrateDigger.entitlements").filter { !$0.isWhitespace }
        XCTAssertTrue(entitlements.contains("<key>com.apple.security.device.audio-input</key><true/>"),
                      "The hardened runtime gives Ambient silence without com.apple.security.device.audio-input")
    }
}
