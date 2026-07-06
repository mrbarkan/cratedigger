import XCTest
@testable import CrateDiggerCore

final class SemanticVersionTests: XCTestCase {
    private func v(_ tag: String) -> SemanticVersion {
        guard let parsed = SemanticVersion(tag: tag) else {
            XCTFail("could not parse \(tag)")
            fatalError()
        }
        return parsed
    }

    func testParsing() {
        let rc = v("v1.0.0-rc.33")
        XCTAssertEqual(rc.major, 1)
        XCTAssertEqual(rc.minor, 0)
        XCTAssertEqual(rc.patch, 0)
        XCTAssertEqual(rc.prerelease, ["rc", "33"])

        let stable = v("1.2.3")
        XCTAssertEqual(stable.prerelease, [])

        XCTAssertNil(SemanticVersion(tag: "1.0"))
        XCTAssertNil(SemanticVersion(tag: "not-a-version"))
        XCTAssertNil(SemanticVersion(tag: ""))
    }

    func testBuildMetadataIgnored() {
        XCTAssertEqual(v("1.0.0+build.5"), v("1.0.0"))
    }

    func testOrdering() {
        // Stable outranks its own prereleases.
        XCTAssertLessThan(v("1.0.0-rc.33"), v("1.0.0"))
        // Numeric prerelease compare, not lexical: rc.4 < rc.33.
        XCTAssertLessThan(v("1.0.0-rc.4"), v("1.0.0-rc.33"))
        // Core triple dominates the prerelease.
        XCTAssertLessThan(v("1.0.0"), v("1.0.1-rc.1"))
        XCTAssertLessThan(v("1.9.0"), v("1.10.0"))
        // Equal versions are not ordered.
        XCTAssertFalse(v("1.0.0-rc.33") < v("v1.0.0-rc.33"))
        XCTAssertFalse(v("1.0.0") < v("1.0.0"))
        // More prerelease identifiers rank higher when the prefix matches.
        XCTAssertLessThan(v("1.0.0-rc"), v("1.0.0-rc.1"))
    }
}

final class UpdateCheckServiceTests: XCTestCase {
    private struct StubFeed: UpdateFeedFetching {
        let json: String
        func fetchReleasesJSON() async throws -> Data { Data(json.utf8) }
    }

    private static func releaseJSON(
        tag: String,
        prerelease: Bool = true,
        draft: Bool = false,
        withDMG: Bool = true
    ) -> String {
        let assets = withDMG
            ? #"[{"name": "CrateDigger-1.0.0.dmg", "browser_download_url": "https://example.com/CrateDigger-1.0.0.dmg"}]"#
            : "[]"
        return """
        {
          "tag_name": "\(tag)",
          "name": "CrateDigger \(tag)",
          "body": "Notes for \(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "html_url": "https://github.com/mrbarkan/cratedigger/releases/tag/\(tag)",
          "assets": \(assets)
        }
        """
    }

    func testParseDropsDraftsAndUnparseableTags() throws {
        let json = "[\(Self.releaseJSON(tag: "v1.0.0-rc.33")), \(Self.releaseJSON(tag: "v1.0.0-rc.34", draft: true)), \(Self.releaseJSON(tag: "nightly"))]"
        let releases = try UpdateCheckService.parseReleases(Data(json.utf8))
        XCTAssertEqual(releases.map(\.tagName), ["v1.0.0-rc.33"])
        XCTAssertEqual(releases[0].dmgAssetURL?.lastPathComponent, "CrateDigger-1.0.0.dmg")
        XCTAssertEqual(releases[0].notes, "Notes for v1.0.0-rc.33")
    }

    func testNewestEligibleRespectsChannelAndOrder() throws {
        let json = "[\(Self.releaseJSON(tag: "v1.0.0-rc.4")), \(Self.releaseJSON(tag: "v1.0.0-rc.33")), \(Self.releaseJSON(tag: "v0.9.0", prerelease: false))]"
        let releases = try UpdateCheckService.parseReleases(Data(json.utf8))

        // RC channel: highest by semver, not feed order (rc.33 beats rc.4).
        XCTAssertEqual(
            UpdateCheckService.newestEligible(releases, includePrereleases: true)?.tagName,
            "v1.0.0-rc.33"
        )
        // Stable channel never sees prereleases.
        XCTAssertEqual(
            UpdateCheckService.newestEligible(releases, includePrereleases: false)?.tagName,
            "v0.9.0"
        )
    }

    func testUpdateAvailableOnlyWhenStrictlyNewer() async throws {
        let feed = StubFeed(json: "[\(Self.releaseJSON(tag: "v1.0.0-rc.33"))]")
        let service = UpdateCheckService(feed: feed)
        let current = SemanticVersion(tag: "1.0.0-rc.32")!

        let result = try await service.checkForUpdate(currentVersion: current, includePrereleases: true)
        guard case .updateAvailable(let release) = result else {
            return XCTFail("expected an update, got \(result)")
        }
        XCTAssertEqual(release.tagName, "v1.0.0-rc.33")

        // Same version → up to date; never offer a downgrade either.
        let same = try await service.checkForUpdate(
            currentVersion: SemanticVersion(tag: "1.0.0-rc.33")!, includePrereleases: true)
        XCTAssertEqual(same, .upToDate)
        let newer = try await service.checkForUpdate(
            currentVersion: SemanticVersion(tag: "1.0.0")!, includePrereleases: true)
        XCTAssertEqual(newer, .upToDate)
    }

    func testMalformedFeedThrowsDecodingError() async {
        let service = UpdateCheckService(feed: StubFeed(json: #"{"message": "rate limited"}"#))
        do {
            _ = try await service.checkForUpdate(
                currentVersion: SemanticVersion(tag: "1.0.0")!, includePrereleases: false)
            XCTFail("expected a decoding error")
        } catch let error as UpdateCheckError {
            guard case .decodingFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
