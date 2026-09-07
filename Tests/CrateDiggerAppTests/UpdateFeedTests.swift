import XCTest
@testable import CrateDiggerApp

/// The one branch that decides who is offered a prerelease.
///
/// Worth pinning because the failure is silent and lands on other people's
/// Macs: get it backwards and every stable copy starts reading the 2.0 beta
/// feed, and nothing in the app would say so.
final class UpdateFeedTests: XCTestCase {

    /// The case that matters. A shipping build, nobody having touched the
    /// setting, must be left on the Info.plist feed.
    func testStableBuildWithoutOptInIsLeftAlone() {
        XCTAssertNil(UpdateFeed.override(channel: "", betaOptIn: false))
    }

    func testStableBuildOptingInReadsTheBetaFeed() {
        XCTAssertEqual(UpdateFeed.override(channel: "", betaOptIn: true), UpdateFeed.beta)
    }

    /// A beta build keeps following the line it came from, whatever the
    /// setting says: sending it to the stable feed would strand it, since the
    /// newest stable version is older than the beta already installed.
    func testBetaBuildStaysOnTheBetaFeedEvenWithTheSettingOff() {
        XCTAssertEqual(UpdateFeed.override(channel: "BETA", betaOptIn: false), UpdateFeed.beta)
        XCTAssertEqual(UpdateFeed.override(channel: "RC", betaOptIn: false), UpdateFeed.beta)
    }

    /// The two feeds must never collapse to one file, which is the property
    /// the whole scheme rests on.
    func testTheFeedsAreDifferentFiles() {
        XCTAssertNotEqual(UpdateFeed.stable, UpdateFeed.beta)
    }

    /// `UpdateFeed.stable` documents what Info.plist carries; if somebody
    /// repoints the plist, this catches the drift rather than letting the
    /// comment quietly become a lie.
    func testStableConstantMatchesTheShippedFeedURL() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CrateDiggerAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Packaging/CrateDiggerApp/Info.plist")
        let contents = try String(contentsOf: plist, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("<string>\(UpdateFeed.stable)</string>"),
            "Info.plist SUFeedURL no longer matches UpdateFeed.stable"
        )
    }
}
