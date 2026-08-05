#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class StreamFailureAdvisorTests: XCTestCase {

    private func diagnose(_ detail: String) -> StreamFailureAdvisor.Diagnosis {
        StreamFailureAdvisor.diagnose(detail: detail, ytdlpInstalled: true)
    }

    func testMissingYtDlpLeadsWithInstall() {
        let d = StreamFailureAdvisor.diagnose(detail: nil, ytdlpInstalled: false)
        XCTAssertEqual(d.primaryRemedy, .installYtDlp)
        XCTAssertTrue(d.remedies.contains(.useWebViewEngine))
    }

    /// The signature of a YouTube-side change — the case an update actually fixes.
    func testExtractorFailuresLeadWithUpdate() {
        for detail in [
            "ERROR: [youtube] jNQXAC9IVRw: nsig extraction failed: Some formats may be missing",
            "ERROR: unable to extract player response",
            "ERROR: [youtube] Signature extraction failed",
            "ERROR: unable to download video data: HTTP Error 403: Forbidden"
        ] {
            XCTAssertEqual(diagnose(detail).primaryRemedy, .updateYtDlp, "for: \(detail)")
        }
    }

    func testBotChallengeSuggestsUpdateFirst() {
        let d = diagnose("ERROR: Sign in to confirm you’re not a bot. Use --cookies-from-browser")
        XCTAssertEqual(d.primaryRemedy, .updateYtDlp)
        XCTAssertTrue(d.remedies.contains(.waitAndRetry))
    }

    /// A dead video is not a broken install — offering "update yt-dlp" here
    /// sends people to fix something that works.
    func testDeadOrPrivateVideoDoesNotSuggestUpdating() {
        for detail in [
            "ERROR: [youtube] abc: Private video. Sign in if you've been granted access",
            "ERROR: [youtube] abc: Video unavailable",
            "ERROR: This live event has ended."
        ] {
            let d = diagnose(detail)
            XCTAssertEqual(d.primaryRemedy, .tryAnotherSource, "for: \(detail)")
            XCTAssertFalse(d.remedies.contains(.updateYtDlp), "should not blame yt-dlp for: \(detail)")
        }
    }

    func testAgeRestrictionIsNotAnUpdateProblem() {
        let d = diagnose("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.")
        XCTAssertEqual(d.primaryRemedy, .tryAnotherSource)
        XCTAssertFalse(d.remedies.contains(.updateYtDlp))
    }

    func testRateLimitSuggestsWaiting() {
        let d = diagnose("ERROR: HTTP Error 429: Too Many Requests")
        XCTAssertEqual(d.primaryRemedy, .waitAndRetry)
        XCTAssertFalse(d.remedies.contains(.updateYtDlp))
    }

    func testNetworkFailureSuggestsRetryOnly() {
        let d = diagnose("ERROR: unable to download webpage: <urlopen error Temporary failure in name resolution>")
        XCTAssertEqual(d.primaryRemedy, .waitAndRetry)
    }

    func testBadURLAsksForTheURL() {
        let d = diagnose("ERROR: 'not a link' is not a valid URL. Set --default-search")
        XCTAssertEqual(d.primaryRemedy, .fixURL)
    }

    func testUnrecognisedFailureFallsBackToUpdate() {
        let d = diagnose("ERROR: something nobody has seen before")
        XCTAssertEqual(d.primaryRemedy, .updateYtDlp)
        XCTAssertNotNil(d.detail)
    }

    func testEveryDiagnosisOffersAtLeastOneRemedy() {
        for detail in ["", "ERROR: whatever", "Private video", "HTTP Error 429"] {
            XCTAssertFalse(diagnose(detail).remedies.isEmpty, "no remedy for: \(detail)")
        }
    }

    func testWorkingVerdictProducesNoDiagnosis() {
        XCTAssertNil(StreamFailureAdvisor.diagnose(.working(version: "2026.01.01")))
    }

    func testBrokenVerdictIsDiagnosed() {
        let d = StreamFailureAdvisor.diagnose(.broken(version: "2024.01.01", detail: "nsig extraction failed"))
        XCTAssertEqual(d?.primaryRemedy, .updateYtDlp)
    }
}

final class StreamSuggestionTests: XCTestCase {
    func testCatalogIsNonEmptyAndUniquelyIdentified() {
        let catalog = StreamSuggestion.catalog
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count, "duplicate suggestion ids")
        XCTAssertEqual(Set(catalog.map(\.url)).count, catalog.count, "duplicate suggestion urls")
    }

    func testEveryCategoryHasSuggestions() {
        for category in RadioCategory.allCases {
            XCTAssertFalse(StreamSuggestion.catalog(for: category).isEmpty,
                           "no suggestions for \(category)")
        }
    }

    /// Every suggestion must survive the same parser a pasted URL goes through,
    /// or tapping it would fail the way a typo does.
    func testEverySuggestedURLParses() {
        for suggestion in StreamSuggestion.catalog {
            XCTAssertNotNil(StreamURLParser.parse(suggestion.url),
                            "\(suggestion.title) has an unparseable URL: \(suggestion.url)")
        }
    }

    func testSuggestionsCarryUserFacingCopy() {
        for suggestion in StreamSuggestion.catalog {
            XCTAssertFalse(suggestion.title.isEmpty)
            XCTAssertFalse(suggestion.channel.isEmpty)
            XCTAssertFalse(suggestion.blurb.isEmpty)
        }
    }
}
#endif
