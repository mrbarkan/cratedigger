import XCTest
@testable import CrateDiggerCore

final class ChunkedStreamLoaderTests: XCTestCase {

    // MARK: - URL wrapping

    func testWrapAndUnwrapRoundTripsQueryAndPath() throws {
        let original = URL(string: "https://rr1.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4&n=abc")!
        let wrapped = try XCTUnwrap(ChunkedStreamLoader.wrap(original))

        XCTAssertEqual(wrapped.scheme, "cdchunk-https")
        XCTAssertTrue(ChunkedStreamLoader.isWrapped(wrapped))
        XCTAssertEqual(ChunkedStreamLoader.unwrap(wrapped), original)
    }

    func testWrapRefusesAnAlreadyWrappedURL() {
        let wrapped = ChunkedStreamLoader.wrap(URL(string: "https://example.com/a.m4a")!)!
        XCTAssertNil(ChunkedStreamLoader.wrap(wrapped))
    }

    func testUnwrapReturnsNilForAPlainURL() {
        XCTAssertNil(ChunkedStreamLoader.unwrap(URL(string: "https://example.com/a.m4a")!))
    }

    /// HLS is already one bounded request per segment, and interposing would
    /// break AVPlayer's variant handling — it must pass through untouched.
    func testWrapIfProgressiveLeavesHLSAndLocalFilesAlone() {
        let hls = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/x/index.m3u8")!
        XCTAssertEqual(ChunkedStreamLoader.wrapIfProgressive(hls), hls)

        let local = URL(fileURLWithPath: "/Users/me/Music/track.flac")
        XCTAssertEqual(ChunkedStreamLoader.wrapIfProgressive(local), local)
    }

    func testWrapIfProgressiveWrapsRemoteProgressiveAudio() {
        let dash = URL(string: "https://rr1.googlevideo.com/videoplayback?itag=140")!
        XCTAssertTrue(ChunkedStreamLoader.isWrapped(ChunkedStreamLoader.wrapIfProgressive(dash)))
    }

    // MARK: - Chunk arithmetic

    func testChunksTileTheRangeExactlyOnce() {
        let chunk: Int64 = 1000
        var offset: Int64 = 0
        var covered: [ClosedRange<Int64>] = []
        while let next = ChunkedStreamLoader.nextChunk(from: offset, through: 2500, chunkSize: chunk) {
            covered.append(next)
            offset = next.upperBound + 1
        }

        XCTAssertEqual(covered, [0...999, 1000...1999, 2000...2500])
    }

    func testChunkIsClampedToTheLastByteAndStopsPastTheEnd() {
        XCTAssertEqual(ChunkedStreamLoader.nextChunk(from: 90, through: 99, chunkSize: 1000), 90...99)
        XCTAssertNil(ChunkedStreamLoader.nextChunk(from: 100, through: 99, chunkSize: 1000))
    }

    // MARK: - Content-Range parsing

    func testTotalLengthReadsTheSizeAfterTheSlash() {
        XCTAssertEqual(ChunkedStreamLoader.totalLength(fromContentRange: "bytes 0-1/88426261"), 88_426_261)
    }

    func testTotalLengthRejectsTheUnknownSizeForm() {
        XCTAssertNil(ChunkedStreamLoader.totalLength(fromContentRange: "bytes 0-1/*"))
    }
}
