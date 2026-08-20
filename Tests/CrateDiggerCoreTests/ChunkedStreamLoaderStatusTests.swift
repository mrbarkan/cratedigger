#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// A failing chunk used to reach the user as URLError's canned "There was a bad
/// response from the server" — the status code was attached but discarded, so a
/// 403 from a stale extractor looked like any other network fault.
final class ChunkedStreamLoaderStatusTests: XCTestCase {

    func testForbiddenNamesTheStatusAndTheUsualCause() {
        let message = ChunkedStreamLoader.message(forStatus: 403)
        XCTAssertTrue(message.contains("403"), message)
        XCTAssertTrue(message.lowercased().contains("yt-dlp"), message)
    }

    func testExpiredURLIsCalledOutSeparately() {
        for code in [404, 410] {
            XCTAssertTrue(ChunkedStreamLoader.message(forStatus: code).contains("expired"),
                          "status \(code)")
        }
    }

    func testAnyOtherStatusStillNamesItself() {
        XCTAssertTrue(ChunkedStreamLoader.message(forStatus: 500).contains("500"))
    }

    /// The advisor classifies on the message text, so the loader's wording has
    /// to land in the branch that offers "update yt-dlp".
    func testTheAdvisorRecognisesTheLoadersForbiddenMessage() {
        let diagnosis = StreamFailureAdvisor.diagnose(
            detail: ChunkedStreamLoader.message(forStatus: 403),
            ytdlpInstalled: true
        )
        XCTAssertTrue(diagnosis.remedies.contains(.updateYtDlp),
                      "403 must offer the update remedy, got \(diagnosis.remedies)")
    }
}
#endif
