#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The judgement in DEEP SCAN lives in two pure functions: what we make of an
/// AcoustID response, and how the album's files vote on a release. Both decide
/// what gets written to somebody's files, so both are tested offline.
final class AcoustIDClientTests: XCTestCase {

    private func fingerprint(_ value: String = "AQADtEmiRIkS", duration: Int = 292) -> AudioFingerprint {
        AudioFingerprint(
            fileURL: URL(fileURLWithPath: "/Music/a.flac"),
            durationSeconds: duration,
            fingerprint: value
        )
    }

    // MARK: - Request

    func testFormBodyCarriesKeyDurationFingerprintAndMeta() {
        let body = AcoustIDClient.formBody(apiKey: "testkey", fingerprint: fingerprint())
        XCTAssertTrue(body.contains("client=testkey"))
        XCTAssertTrue(body.contains("duration=292"))
        XCTAssertTrue(body.contains("fingerprint=AQADtEmiRIkS"))
        // Without releaseids there is nothing for the files to vote on.
        XCTAssertTrue(body.contains("meta=recordings+releaseids"))
    }

    func testFormBodyPercentEncodesReservedCharacters() {
        let body = AcoustIDClient.formBody(apiKey: "a&b=c", fingerprint: fingerprint("AQ+D/tEmi="))
        XCTAssertTrue(body.contains("client=a%26b%3Dc"))
        XCTAssertTrue(body.contains("fingerprint=AQ%2BD%2FtEmi%3D"))
        // Exactly three fields plus meta — an unescaped "&" would make more.
        XCTAssertEqual(body.split(separator: "&").count, 4)
    }

    // MARK: - Response parsing

    private let response = """
    {"status":"ok","results":[
        {"id":"acoustid-1","score":0.97,"recordings":[
            {"id":"rec-fine-time","releases":[{"id":"rel-technique"},{"id":"rel-singles"}]}
        ]},
        {"id":"acoustid-2","score":0.61,"recordings":[
            {"id":"rec-wrong","releases":[{"id":"rel-nope"}]}
        ]}
    ]}
    """

    func testParsePicksTheBestScoringResult() throws {
        let recordings = try AcoustIDClient.parse(Data(response.utf8))
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].id, "rec-fine-time")
        XCTAssertEqual(recordings[0].releaseIDs, ["rel-technique", "rel-singles"])
    }

    func testParseDropsResultsAcoustIDIsUnsureAbout() throws {
        let weak = """
        {"status":"ok","results":[{"id":"a","score":0.2,"recordings":[{"id":"r","releases":[{"id":"x"}]}]}]}
        """
        XCTAssertTrue(try AcoustIDClient.parse(Data(weak.utf8)).isEmpty)
    }

    func testParseHandlesNoResultsAsEmptyRatherThanAnError() throws {
        XCTAssertTrue(try AcoustIDClient.parse(Data(#"{"status":"ok","results":[]}"#.utf8)).isEmpty)
    }

    func testParseFallsBackToTopLevelReleasesWhenThereIsNoRecordingBreakdown() throws {
        let flat = """
        {"status":"ok","results":[{"id":"a","score":0.9,"releases":[{"id":"rel-technique"}]}]}
        """
        let recordings = try AcoustIDClient.parse(Data(flat.utf8))
        XCTAssertEqual(recordings.map(\.releaseIDs), [["rel-technique"]])
    }

    func testParseMalformedJSONThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try AcoustIDClient.parse(Data("<html>502</html>".utf8)))
    }

    // MARK: - Service errors

    func testInvalidKeyIsRecognisedRatherThanReadAsNoMatch() {
        // The exact body AcoustID returns when the account API key is used where
        // an application key belongs. Reported live on 2026-08-29.
        let body = #"{"error": {"code": 4, "message": "invalid API key"}, "status": "error"}"#
        let error = AcoustIDClient.serviceError(in: Data(body.utf8))
        XCTAssertEqual(error, .service(code: 4, message: "invalid API key"))
        XCTAssertTrue(try XCTUnwrap(error).isInvalidKey)
    }

    func testOtherServiceErrorsAreCarriedButNotMistakenForAKeyProblem() throws {
        let body = #"{"error": {"code": 2, "message": "missing required parameter \"client\""}, "status": "error"}"#
        let error = try XCTUnwrap(AcoustIDClient.serviceError(in: Data(body.utf8)))
        XCTAssertFalse(error.isInvalidKey)
    }

    func testASuccessfulResponseCarriesNoServiceError() {
        XCTAssertNil(AcoustIDClient.serviceError(in: Data(response.utf8)))
        XCTAssertNil(AcoustIDClient.serviceError(in: Data("<html>502</html>".utf8)))
    }

    // MARK: - The vote

    private func recording(_ id: String, _ releases: [String]) -> AcoustIDRecording {
        AcoustIDRecording(id: id, releaseIDs: releases)
    }

    func testTheReleaseMostFilesAgreeOnWins() {
        let ballots = [
            [recording("r1", ["album", "hits"])],
            [recording("r2", ["album"])],
            [recording("r3", ["album"])]
        ]
        XCTAssertEqual(AcoustIDClient.rankReleases(ballots).first, "album")
    }

    func testOneFileCannotStuffTheBallotWithManyCompilations() {
        // A single track listed on three compilations must not outvote the album
        // two files actually agree on.
        let ballots = [
            [recording("r1", ["comp-a", "comp-b", "comp-c"]), recording("r1-alt", ["comp-a", "comp-b", "comp-c"])],
            [recording("r2", ["album"])],
            [recording("r3", ["album"])]
        ]
        XCTAssertEqual(AcoustIDClient.rankReleases(ballots).first, "album")
    }

    func testRankingIsDeterministicOnATie() {
        let ballots = [[recording("r1", ["first", "second"])]]
        XCTAssertEqual(AcoustIDClient.rankReleases(ballots), AcoustIDClient.rankReleases(ballots))
    }

    func testEmptyReleaseIDsNeverBecomeCandidates() {
        XCTAssertTrue(AcoustIDClient.rankReleases([[recording("r1", [""])]]).isEmpty)
        XCTAssertTrue(AcoustIDClient.rankReleases([]).isEmpty)
    }

    func testVoteShareIsTheFractionOfRecognisedFilesOnThatRelease() {
        let ballots = [
            [recording("r1", ["album"])],
            [recording("r2", ["album"])],
            [recording("r3", ["elsewhere"])]
        ]
        XCTAssertEqual(AcoustIDClient.voteShare(of: "album", in: ballots), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(AcoustIDClient.voteShare(of: "nothing", in: ballots), 0)
        XCTAssertEqual(AcoustIDClient.voteShare(of: "album", in: []), 0)
    }
}
#endif
