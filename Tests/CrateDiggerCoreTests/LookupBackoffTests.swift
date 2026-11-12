import XCTest
@testable import CrateDiggerCore

/// How the background worker waits after a failed lookup, and what a
/// failure means for the artist it was looking up.
final class LookupBackoffTests: XCTestCase {
    func testBackoffDoublesAndResets() {
        let pauses = (0...9).map(ArtistLookupScheduler.backoff(afterFailures:))
        XCTAssertEqual(pauses, [.zero, .seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(480),
                                .seconds(960), .seconds(1_800), .seconds(1_800), .seconds(1_800)],
                       "from 30 s, doubling, never over 30 minutes")
        XCTAssertEqual(ArtistLookupScheduler.backoff(afterFailures: 10_000), .seconds(1_800), "no overflow")
        // A success sets the count back to zero, and zero is no pause.
        XCTAssertEqual(ArtistLookupScheduler.backoff(afterFailures: 0), .zero)
        XCTAssertEqual(ArtistLookupScheduler.backoff(afterFailures: -1), .zero)
    }

    func testWhatAFailureMeans() {
        let classify = ArtistLookupScheduler.failure(_:)
        // The network or a service not answering: the same artist again later.
        XCTAssertEqual(classify(ArtistPictureSourceError.transport("offline")), .retryLater)
        XCTAssertEqual(classify(ArtistPictureSourceError.http(503)), .retryLater)
        XCTAssertEqual(classify(ArtistPictureSourceError.http(429)), .retryLater)
        XCTAssertEqual(classify(ArtistPictureSourceError.quota), .retryLater)
        XCTAssertEqual(classify(URLError(.notConnectedToInternet)), .retryLater)
        XCTAssertEqual(classify(ArtistLookupError.timedOut), .retryLater)
        // An answer that cannot be used for this artist: not again this session.
        XCTAssertEqual(classify(ArtistPictureSourceError.malformed), .skipArtist)
        XCTAssertEqual(classify(ArtistPictureSourceError.http(400)), .skipArtist)
        XCTAssertEqual(classify(ArtistLookupError.pictureLookupFailed("deezer")), .skipArtist)
        XCTAssertEqual(classify(ArtistLookupError.notLookedUp("Various Artists")), .skipArtist)
        // A store that cannot be written: stop until it is made again.
        XCTAssertEqual(classify(ArtistProfileStoreError.unreadableStore(path: "/x")), .stopWorker)
        XCTAssertEqual(classify(ArtistProfileStoreError.unreachableIndexFolder(path: "/x")), .stopWorker)
        // A photo the store will not keep is that artist's problem only.
        XCTAssertEqual(classify(ArtistProfileStoreError.photoTooLarge), .skipArtist)
        // Cancellation is the worker stopping, not a failure.
        XCTAssertNil(classify(CancellationError()))
    }
}
