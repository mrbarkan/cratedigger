#if canImport(XCTest)
import Foundation
import AppKit
import XCTest
@testable import CrateDiggerCore

final class RemoteArtworkServiceTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
        static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            MockURLProtocol.requestCount += 1
            guard let handler = MockURLProtocol.requestHandler else {
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data = data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var service: RemoteArtworkService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = RemoteArtworkService(session: URLSession(configuration: config))
        MockURLProtocol.requestCount = 0
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func caaJSON(imageCount: Int) -> Data {
        let images = (0..<imageCount).map { i in
            """
            {"image": "http://coverartarchive.org/release/x/\(i).jpg",
             "thumbnails": {"250": "http://coverartarchive.org/release/x/\(i)-250.jpg"},
             "types": ["Front"], "front": true, "back": false}
            """
        }.joined(separator: ",")
        return Data("{\"images\": [\(images)]}".utf8)
    }

    private func respond(status: Int, data: Data?) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    func testCoverArtImageCountDecodesList() async {
        respond(status: 200, data: caaJSON(imageCount: 3))
        let count = await service.coverArtImageCount(releaseMBID: "mbid-1")
        XCTAssertEqual(count, 3)
    }

    func testCoverArtImageCount404IsZero() async {
        respond(status: 404, data: nil)
        let count = await service.coverArtImageCount(releaseMBID: "mbid-404")
        XCTAssertEqual(count, 0)
    }

    func testSecondFetchForSameReleaseUsesCache() async throws {
        respond(status: 200, data: caaJSON(imageCount: 2))
        _ = await service.coverArtImageCount(releaseMBID: "mbid-cache")
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-cache")
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "count probe should prime the cache for GET ARTWORK")
    }

    func test404IsCachedAsEmpty() async {
        respond(status: 404, data: nil)
        _ = await service.coverArtImageCount(releaseMBID: "mbid-empty")
        _ = await service.coverArtImageCount(releaseMBID: "mbid-empty")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    /// The HD badge used to trust Cover Art Archive's "1200" thumbnail tier,
    /// which CAA lists even for 600px originals. `probeDimensions` reads the
    /// real size out of the image header, so it must work on a *truncated*
    /// file — that's all a 64 KB range request returns.
    func testProbeDimensionsReadsSizeFromATruncatedHeader() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1425, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).jpg")
        try jpeg.prefix(65536).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = await RemoteArtworkService().probeDimensions(of: url)
        XCTAssertEqual(size?.width, 1425)
        XCTAssertEqual(size?.height, 900)
    }

    func testServerErrorIsNotCached() async {
        respond(status: 503, data: nil)
        _ = await service.coverArtImageCount(releaseMBID: "mbid-flaky")
        respond(status: 200, data: caaJSON(imageCount: 1))
        let count = await service.coverArtImageCount(releaseMBID: "mbid-flaky")
        XCTAssertEqual(count, 1, "a 503 must not be remembered as 'no images'")
    }
}

final class ArtworkSearchLoosenessTests: XCTestCase {
    func testStrippedEditionTitleDropsParentheticalAndBracketGroups() {
        XCTAssertEqual(RemoteArtworkService.strippedEditionTitle("OK Computer (Collector's Edition) [2017 Remaster]"),
                       "OK Computer")
        XCTAssertEqual(RemoteArtworkService.strippedEditionTitle("Kid A"), "Kid A")
        XCTAssertEqual(RemoteArtworkService.strippedEditionTitle("  In Rainbows (Disk 2)  "), "In Rainbows")
        // A title that is nothing but a parenthetical must not strip to "".
        XCTAssertEqual(RemoteArtworkService.strippedEditionTitle("(What's the Story) Morning Glory?"),
                       "Morning Glory?")
    }

    func testQueryAttemptsGoStrictToLoose() {
        let attempts = RemoteArtworkService.musicBrainzQueryAttempts(
            artist: "Radiohead", album: "OK Computer (Collector's Edition)")
        XCTAssertEqual(attempts, [
            "artist:\"Radiohead\" AND release:\"OK Computer (Collector's Edition)\"",
            "artist:\"Radiohead\" AND release:\"OK Computer\"",
            "artist:(Radiohead) AND release:(OK Computer)"
        ])
    }

    func testPlainTitleGetsTwoAttempts() {
        let attempts = RemoteArtworkService.musicBrainzQueryAttempts(artist: "Radiohead", album: "Kid A")
        XCTAssertEqual(attempts, [
            "artist:\"Radiohead\" AND release:\"Kid A\"",
            "artist:(Radiohead) AND release:(Kid A)"
        ])
    }

    func testAlbumOnlyQueryOmitsArtistField() {
        let attempts = RemoteArtworkService.musicBrainzQueryAttempts(artist: "", album: "Kid A")
        XCTAssertEqual(attempts.first, "release:\"Kid A\"")
        XCTAssertFalse(attempts.contains(where: { $0.contains("artist:") }))
    }
}

/// Deezer is the fallback provider when iTunes has no match — it covers small
/// labels and non-US catalogue that the store misses.
final class DeezerArtworkTests: XCTestCase {
    func testSearchURLScopesTermsToArtistAndAlbumFields() throws {
        let url = try XCTUnwrap(RemoteArtworkService.deezerSearchURL(artist: "Boards of Canada",
                                                                    album: "Geogaddi"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.deezer.com")
        XCTAssertEqual(components.path, "/search/album")
        let q = try XCTUnwrap(components.queryItems?.first { $0.name == "q" }?.value)
        XCTAssertTrue(q.contains("artist:\"Boards of Canada\""))
        XCTAssertTrue(q.contains("album:\"Geogaddi\""))
    }

    func testSearchURLIsNilWithNothingToSearchFor() {
        XCTAssertNil(RemoteArtworkService.deezerSearchURL(artist: "", album: ""))
    }

    /// An unescaped quote inside a quoted term makes Deezer reject the query.
    func testSearchURLStripsQuotesFromTerms() throws {
        let url = try XCTUnwrap(RemoteArtworkService.deezerSearchURL(artist: "Quo\"te", album: "A\"lbum"))
        let q = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value)
        XCTAssertEqual(q, "artist:\"Quote\" album:\"Album\"")
    }

    func testParsePrefersTheLargestCoverAndBestMatch() throws {
        let json = """
        { "data": [
            { "title": "Geogaddi (Deluxe)", "artist": { "name": "Boards of Canada" },
              "cover": "https://e.deezer.com/s.jpg", "cover_big": "https://e.deezer.com/b.jpg",
              "cover_xl": "https://e.deezer.com/xl-deluxe.jpg" },
            { "title": "Geogaddi", "artist": { "name": "Boards of Canada" },
              "cover_xl": "https://e.deezer.com/xl.jpg" }
        ] }
        """.data(using: .utf8)!

        let candidate = try XCTUnwrap(
            RemoteArtworkService.parseDeezer(json, artist: "Boards of Canada", album: "Geogaddi")
        )
        XCTAssertEqual(candidate.album, "Geogaddi", "the exact title should win over the deluxe edition")
        XCTAssertEqual(candidate.artworkURL.absoluteString, "https://e.deezer.com/xl.jpg")
    }

    func testParseFallsBackThroughCoverSizes() throws {
        let json = """
        { "data": [ { "title": "X", "artist": { "name": "Y" }, "cover": "https://e.deezer.com/s.jpg" } ] }
        """.data(using: .utf8)!
        let candidate = try XCTUnwrap(RemoteArtworkService.parseDeezer(json, artist: "Y", album: "X"))
        XCTAssertEqual(candidate.artworkURL.absoluteString, "https://e.deezer.com/s.jpg")
    }

    func testParseReturnsNilOnEmptyOrMalformedPayloads() {
        for payload in [#"{"data": []}"#, #"{}"#, "not json", #"{"data":[{"title":"X"}]}"#] {
            XCTAssertNil(
                RemoteArtworkService.parseDeezer(payload.data(using: .utf8)!, artist: "Y", album: "X"),
                "should not produce a candidate from: \(payload)"
            )
        }
    }
}
#endif
