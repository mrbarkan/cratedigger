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
        service = RemoteArtworkService(session: URLSession(configuration: config),
                                       musicBrainzInterval: 0, retryDelay: 0)
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

    // MARK: - MusicBrainz search resilience

    /// The search walks a ladder of progressively looser queries. The strict
    /// first rung is the one most likely to fail, so a timeout there must not
    /// take the looser rungs down with it — that turned a slow MusicBrainz into
    /// "Network error: the request timed out" for searches that would have
    /// succeeded on the next attempt.
    func testASlowFirstQueryDoesNotSinkTheWholeSearch() async throws {
        var attempt = 0
        MockURLProtocol.requestHandler = { request in
            attempt += 1
            if attempt == 1 { throw URLError(.timedOut) }
            let body = Data("""
            {"releases": [{"id": "mbid-2", "title": "Paracosm", "date": "2013"}]}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let releases = try await service.searchMusicBrainzReleases(artist: "Washed Out", album: "Paracosm")
        XCTAssertEqual(releases.map(\.id), ["mbid-2"])
        XCTAssertGreaterThan(attempt, 1, "the ladder must have carried on past the failed rung")
    }

    /// Every rung failing is a real failure, and must still reach the user.
    func testASearchWhereEveryQueryFailsStillThrows() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await service.searchMusicBrainzReleases(artist: "Washed Out", album: "Paracosm")
            XCTFail("expected the failure to surface")
        } catch {
            XCTAssertTrue(error is RemoteArtworkService.FetchError)
        }
    }

    /// MusicBrainz search is far slower than the other endpoints here; the
    /// session-wide 12s was timing out queries that were merely still running.
    func testMusicBrainzGetsALongerTimeoutThanTheSessionDefault() {
        XCTAssertGreaterThan(RemoteArtworkService.musicBrainzTimeout, 12)
    }

    // MARK: - Discogs

    /// Shapes copied from live responses: a MusicBrainz release's url-relations
    /// and a Discogs release payload.
    private func mbRelationsJSON(_ resource: String, type: String = "discogs") -> Data {
        Data("""
        {"title": "A Release", "relations": [
            {"type": "amazon asin", "url": {"resource": "https://www.amazon.com/gp/product/B00001IVAI"}},
            {"type": "\(type)", "url": {"resource": "\(resource)"}}
        ]}
        """.utf8)
    }

    private func discogsReleaseJSON() -> Data {
        Data("""
        {"title": "A Release", "images": [
            {"type": "primary", "uri": "https://i.discogs.com/full-front.jpeg", "uri150": "https://i.discogs.com/t150-front.jpeg", "width": 600, "height": 600},
            {"type": "secondary", "uri": "https://i.discogs.com/full-back.jpeg", "uri150": "https://i.discogs.com/t150-back.jpeg", "width": 600, "height": 509},
            {"type": "secondary", "uri": "https://i.discogs.com/full-label.jpeg", "uri150": "https://i.discogs.com/t150-label.jpeg", "width": 600, "height": 600}
        ]}
        """.utf8)
    }

    private func discogsSearchJSON(_ hits: [(Int, String, String)]) -> Data {
        let body = hits.map { #"{"id": \#($0.0), "title": "\#($0.1)", "year": "\#($0.2)"}"# }
            .joined(separator: ",")
        return Data("{\"results\": [\(body)]}".utf8)
    }

    /// A reissue's sleeve often isn't the one on the shelf, so a year match
    /// outranks Discogs' own ordering.
    func testSearchPrefersTheMatchingYearOverTheFirstHit() {
        let data = discogsSearchJSON([
            (8110401, "Beach House - Teen Dream", "2016"),
            (2111843, "Beach House - Teen Dream", "2010"),
        ])
        XCTAssertEqual(
            RemoteArtworkService.pickDiscogsSearchHit(data, preferredYear: 2010, expectedTitle: "Teen Dream"),
            "2111843"
        )
    }

    func testSearchFallsBackToDiscogsOwnRankingWithoutAYear() {
        let data = discogsSearchJSON([
            (8110401, "Beach House - Teen Dream", "2016"),
            (2111843, "Beach House - Teen Dream", "2010"),
        ])
        XCTAssertEqual(
            RemoteArtworkService.pickDiscogsSearchHit(data, preferredYear: nil, expectedTitle: "Teen Dream"),
            "8110401"
        )
    }

    /// The loose artist+title rung must not hand someone else's scans to an
    /// album folder. Discogs titles read "Artist - Title", so the album has to
    /// appear in there.
    func testSearchRejectsAHitThatIsNotTheAlbum() {
        let data = discogsSearchJSON([(999, "Various - Now That's What I Call Music", "2010")])
        XCTAssertNil(
            RemoteArtworkService.pickDiscogsSearchHit(data, preferredYear: nil, expectedTitle: "Teen Dream")
        )
    }

    /// Punctuation and case differ constantly between the two databases.
    func testSearchMatchesAcrossPunctuationAndCase() {
        let data = discogsSearchJSON([(4242, "Bon Iver - 22, A Million", "2016")])
        XCTAssertEqual(
            RemoteArtworkService.pickDiscogsSearchHit(data, preferredYear: nil, expectedTitle: "22 a million"),
            "4242"
        )
    }

    /// A barcode already identifies the physical object, so no title check.
    func testBarcodeSearchTakesTheHitWithoutATitleCheck() {
        let data = discogsSearchJSON([(777, "Something Entirely Different", "1997")])
        XCTAssertEqual(
            RemoteArtworkService.pickDiscogsSearchHit(data, preferredYear: nil, expectedTitle: nil),
            "777"
        )
    }

    func testEmptySearchResultsResolveToNothing() {
        XCTAssertNil(RemoteArtworkService.pickDiscogsSearchHit(Data(#"{"results": []}"#.utf8),
                                                              preferredYear: nil, expectedTitle: nil))
        XCTAssertNil(RemoteArtworkService.pickDiscogsSearchHit(Data("not json".utf8),
                                                              preferredYear: nil, expectedTitle: nil))
    }

    func testParsesTheDiscogsReleaseIDFromMusicBrainzRelations() {
        let id = RemoteArtworkService.parseDiscogsReleaseID(
            mbRelationsJSON("https://www.discogs.com/release/1722")
        )
        XCTAssertEqual(id, "1722")
    }

    /// A master groups every pressing of an album; its images are not this
    /// release's, so the relation must be ignored rather than followed.
    func testIgnoresADiscogsMasterRelation() {
        let id = RemoteArtworkService.parseDiscogsReleaseID(
            mbRelationsJSON("https://www.discogs.com/master/12345")
        )
        XCTAssertNil(id)
    }

    func testIgnoresRelationsToOtherSites() {
        let id = RemoteArtworkService.parseDiscogsReleaseID(
            mbRelationsJSON("https://rateyourmusic.com/release/album/x", type: "other databases")
        )
        XCTAssertNil(id)
    }

    /// Trailing slugs and query strings are common in stored relations.
    func testParsesADiscogsURLWithTrailingPath() {
        let id = RemoteArtworkService.parseDiscogsReleaseID(
            mbRelationsJSON("https://www.discogs.com/release/1722-Various-For-Beginner-Piano")
        )
        XCTAssertEqual(id, "1722")
    }

    func testDiscogsImagesMarkOnlyThePrimaryAsFront() {
        let images = RemoteArtworkService.parseDiscogsImages(discogsReleaseJSON())
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images.filter(\.front).count, 1, "Discogs marks exactly one primary")
        XCTAssertEqual(images.first?.types, ["Front"])
        // Discogs never says which secondary is the back, so nothing may claim it.
        XCTAssertTrue(images.dropFirst().allSatisfy { $0.types.isEmpty && !$0.back })
        XCTAssertTrue(images.allSatisfy { $0.source == .discogs })
        XCTAssertEqual(images[1].thumbnailURL.absoluteString, "https://i.discogs.com/t150-back.jpeg")
    }

    func testDiscogsImagesSurviveAMissingThumbnail() {
        let data = Data("""
        {"images": [{"type": "primary", "uri": "https://i.discogs.com/only-full.jpeg"}]}
        """.utf8)
        let images = RemoteArtworkService.parseDiscogsImages(data)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].thumbnailURL, images[0].imageURL, "falls back to the full image")
    }

    func testDiscogsGarbageIsNoImagesNotACrash() {
        XCTAssertTrue(RemoteArtworkService.parseDiscogsImages(Data("not json".utf8)).isEmpty)
        XCTAssertNil(RemoteArtworkService.parseDiscogsReleaseID(Data("not json".utf8)))
    }

    func testCoverArtArchiveIndexDecodesList() async throws {
        respond(status: 200, data: caaJSON(imageCount: 3))
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-1")
        XCTAssertEqual(images.count, 3)
    }

    func testCoverArtArchive404IsNoImages() async throws {
        respond(status: 404, data: nil)
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-404")
        XCTAssertEqual(images.count, 0)
    }

    func testSecondFetchForSameReleaseUsesCache() async throws {
        respond(status: 200, data: caaJSON(imageCount: 2))
        _ = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-cache")
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-cache")
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "GET ARTWORK twice must not ask the archive twice")
    }

    func test404IsCachedAsEmpty() async throws {
        respond(status: 404, data: nil)
        _ = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-empty")
        _ = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-empty")
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

    func testServerErrorIsNotCached() async throws {
        respond(status: 503, data: nil)
        _ = try? await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-flaky")
        respond(status: 200, data: caaJSON(imageCount: 1))
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-flaky")
        XCTAssertEqual(images.count, 1, "a 503 must not be remembered as 'no images'")
    }

    // MARK: - Cover Art Archive: honest failures

    /// The regression behind "I can't see the number of images any more". The
    /// archive's index sits behind a redirect to archive.org, which on
    /// 2026-10-12 answered 502 for most releases, and a non-2xx answer was
    /// returned as an empty list: a release with 23 scans read NO IMAGES.
    func testAnArchiveServerErrorThrowsRatherThanReadingAsNoImages() async {
        respond(status: 502, data: Data("<html>502</html>".utf8))
        do {
            let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-502")
            XCTFail("a 502 came back as \(images.count) images")
        } catch let RemoteArtworkService.FetchError.serviceUnavailable(_, status) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "a fast server error gets exactly one retry")
    }

    func testAFastServerErrorIsRetriedOnce() async throws {
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            let status = calls == 1 ? 502 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    status == 200 ? self.caaJSON(imageCount: 4) : nil)
        }
        let images = try await service.fetchCoverArtArchiveImages(releaseMBID: "mbid-retry")
        XCTAssertEqual(images.count, 4)
    }

    /// GET ARTWORK, BACK, GET ARTWORK again while the slow archive is still
    /// answering the first: one request, both callers served.
    func testOverlappingFetchesForOneReleaseShareARequest() async throws {
        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.2)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.caaJSON(imageCount: 2))
        }
        let service = self.service!
        async let first = service.fetchCoverArtArchiveImages(releaseMBID: "mbid-shared")
        async let second = service.fetchCoverArtArchiveImages(releaseMBID: "mbid-shared")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testTheIndexOffersALargeDerivativeForThePreview() throws {
        let data = Data("""
        {"images": [{"image": "http://coverartarchive.org/release/x/1.jpg",
          "thumbnails": {"250": "http://coverartarchive.org/release/x/1-250.jpg",
                         "500": "http://coverartarchive.org/release/x/1-500.jpg",
                         "1200": "http://coverartarchive.org/release/x/1-1200.jpg"},
          "types": ["Front"], "front": true, "back": false}]}
        """.utf8)
        let image = try XCTUnwrap(RemoteArtworkService.parseCoverArtArchiveIndex(data).first)
        XCTAssertEqual(image.thumbnailURL.absoluteString, "https://coverartarchive.org/release/x/1-250.jpg")
        XCTAssertEqual(image.bestPreviewURL.absoluteString, "https://coverartarchive.org/release/x/1-1200.jpg")
        XCTAssertEqual(image.imageURL.absoluteString, "https://coverartarchive.org/release/x/1.jpg",
                       "the original is still what gets staged")
    }

    func testAnImageWithNoDerivativesPreviewsTheOriginal() {
        let image = RemoteArtworkImage(imageURL: URL(string: "https://i.discogs.com/full.jpeg")!,
                                       thumbnailURL: URL(string: "https://i.discogs.com/t150.jpeg")!,
                                       types: [], comment: "", front: false, back: false, source: .discogs)
        XCTAssertEqual(image.bestPreviewURL, image.imageURL)
    }

    // MARK: - Header probes

    func testAFailedProbeIsNotRepeatedOnEveryScroll() async {
        respond(status: 502, data: Data())
        let url = URL(string: "https://coverartarchive.org/release/mbid-x/front")!
        let first = await service.probeDimensions(of: url)
        let second = await service.probeDimensions(of: url)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    // MARK: - Cover Art Archive counts from MusicBrainz

    /// The shape of a live MusicBrainz release browse
    /// (`/ws/2/release?release-group=…`), trimmed to what is read.
    private func browseJSON(total: Int, _ releases: [(String, Int, Bool)]) -> Data {
        let body = releases.map { id, count, front in
            #"{"id": "\#(id)", "title": "OK Computer", "cover-art-archive": {"count": \#(count), "front": \#(front), "back": false, "artwork": \#(count > 0), "darkened": false}}"#
        }.joined(separator: ",")
        return Data(#"{"release-count": \#(total), "release-offset": 0, "releases": [\#(body)]}"#.utf8)
    }

    private func candidate(_ id: String, group: String?) -> MBReleaseCandidate {
        MBReleaseCandidate(id: id, title: "OK Computer", date: nil, country: nil, barcode: nil, format: nil,
                           status: nil, disambiguation: nil, trackCount: nil, releaseGroupID: group)
    }

    func testParsesCoverArtCountsFromABrowse() {
        let parsed = RemoteArtworkService.parseCoverArtBrowse(browseJSON(total: 39, [("a", 23, true), ("b", 0, false)]))
        XCTAssertEqual(parsed.summaries["a"], CoverArtSummary(count: 23, hasFront: true, hasBack: false))
        XCTAssertEqual(parsed.summaries["b"]?.count, 0)
        XCTAssertEqual(parsed.returned, 2)
        XCTAssertEqual(parsed.total, 39)
    }

    /// Thirty results from one release group cost one request, where the old
    /// per-row probe cost thirty trips through archive.org.
    func testOneBrowseCountsEveryPressingInAGroup() async {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("release-group=rg-1"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.browseJSON(total: 3, [("a", 23, true), ("b", 0, false), ("c", 2, true)]))
        }
        var counts: [String: CoverArtSummary?] = [:]
        for await batch in service.coverArtSummaries(for: ["a", "b", "c"].map { candidate($0, group: "rg-1") }) {
            counts.merge(batch) { _, new in new }
        }
        XCTAssertEqual(counts["a"]??.count, 23)
        XCTAssertEqual(counts["b"]??.count, 0)
        XCTAssertEqual(counts["c"]??.count, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    /// A group MusicBrainz couldn't browse leaves its rows *uncounted*, not
    /// at zero, and doesn't stop the next group being counted.
    func testAFailedBrowseLeavesRowsUncountedNotEmpty() async {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("rg-bad") {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.browseJSON(total: 1, [("good", 5, true)]))
        }
        var counts: [String: CoverArtSummary?] = [:]
        for await batch in service.coverArtSummaries(for: [candidate("bad", group: "rg-bad"),
                                                          candidate("good", group: "rg-good")]) {
            counts.merge(batch) { _, new in new }
        }
        XCTAssertEqual(counts.keys.sorted(), ["bad", "good"])
        XCTAssertNil(counts["bad"]!, "an unanswered count is unknown, not zero")
        XCTAssertEqual(counts["good"]??.count, 5)
    }

    func testABigGroupPagesOnlyUntilTheWantedReleasesTurnUp() async throws {
        MockURLProtocol.requestHandler = { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "offset" }!.value!
            let page: [(String, Int, Bool)] = offset == "0"
                ? (0..<100).map { ("p\($0)", 1, true) }
                : [("wanted", 7, true)] + (1..<100).map { ("q\($0)", 1, true) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.browseJSON(total: 450, page))
        }
        let found = try await service.coverArtSummaries(releaseGroupID: "rg-big", wanting: ["wanted"])
        XCTAssertEqual(found["wanted"]?.count, 7)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "stops once the wanted release has turned up")
    }

    func testAReleaseWithNoGroupIsLookedUpOnItsOwn() async {
        respond(status: 200, data: Data(#"{"id": "solo", "title": "X", "cover-art-archive": {"count": 3, "front": true, "back": true, "darkened": false}}"#.utf8))
        var counts: [String: CoverArtSummary?] = [:]
        for await batch in service.coverArtSummaries(for: [candidate("solo", group: nil)]) {
            counts.merge(batch) { _, new in new }
        }
        XCTAssertEqual(counts["solo"] ?? nil, CoverArtSummary(count: 3, hasFront: true, hasBack: true))
    }

    func testDarkenedArtCountsAsNothingToShow() {
        XCTAssertEqual(CoverArtSummary(count: 4, hasFront: true, hasBack: false, darkened: true).available, 0)
        XCTAssertEqual(CoverArtSummary(count: 4, hasFront: true, hasBack: false).available, 4)
    }

    // MARK: - MusicBrainz etiquette

    /// A busy MusicBrainz (503) is retried once and then reported, rather than
    /// passing for a search that found nothing.
    func testABusyMusicBrainzIsAnErrorNotAnEmptySearch() async {
        respond(status: 503, data: Data(#"{"error": "busy"}"#.utf8))
        do {
            _ = try await service.searchMusicBrainzReleases(artist: "Radiohead", album: "OK Computer")
            XCTFail("a busy server read as no results")
        } catch let RemoteArtworkService.FetchError.serviceUnavailable(service, status) {
            XCTAssertEqual(service, "MusicBrainz")
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 3,
                       "two retries on the first rung, and no looser rungs spent on a busy server")
    }

    func testABriefMusicBrainzBusySpellIsRiddenOut() async throws {
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            let busy = calls <= 2
            return (HTTPURLResponse(url: request.url!, statusCode: busy ? 503 : 200, httpVersion: nil, headerFields: nil)!,
                    Data(busy ? #"{"error": "busy"}"#.utf8 : #"{"releases": [{"id": "r", "title": "OK Computer"}]}"#.utf8))
        }
        let releases = try await service.searchMusicBrainzReleases(artist: "Radiohead", album: "OK Computer")
        XCTAssertEqual(releases.map(\.id), ["r"])
    }

    func testRequestsIdentifyTheAppWithAVersionAndAContact() async throws {
        var agent: String?
        MockURLProtocol.requestHandler = { request in
            agent = request.value(forHTTPHeaderField: "User-Agent")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"releases": []}"#.utf8))
        }
        _ = try await service.searchMusicBrainzReleases(artist: "Radiohead", album: "OK Computer")
        let ua = try XCTUnwrap(agent)
        XCTAssertTrue(ua.hasPrefix("CrateDigger/"), ua)
        XCTAssertFalse(ua.hasPrefix("CrateDigger/1.0 "), "the version should be the build's, not a constant")
        XCTAssertTrue(ua.contains("(https://"), "MusicBrainz asks for a contact")
    }

    /// The throttle claims its slot before sleeping. Recording the time only
    /// after the sleep let every caller that arrived during it fire together.
    func testConcurrentMusicBrainzCallsAreSpacedOut() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let throttled = RemoteArtworkService(session: URLSession(configuration: config),
                                             musicBrainzInterval: 0.25, retryDelay: 0)
        let lock = NSLock()
        var starts: [Date] = []
        MockURLProtocol.requestHandler = { request in
            lock.lock(); starts.append(Date()); lock.unlock()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let url = URL(string: "https://musicbrainz.org/ws/2/release/x?fmt=json")!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try? await throttled.musicBrainzData(from: url) } }
        }
        let sorted = starts.sorted()
        XCTAssertEqual(sorted.count, 3)
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 0.2)
        }
    }

    func testSearchHitsCarryArtistGroupAndEveryMedium() async throws {
        respond(status: 200, data: Data(#"""
        {"releases": [{"id": "r1", "title": "Bookends", "date": "1968-04-03", "country": "US",
          "artist-credit": [{"name": "Simon", "joinphrase": " & "}, {"name": "Garfunkel"}],
          "release-group": {"id": "rg-9"},
          "media": [{"format": "12\" Vinyl"}, {"format": "12\" Vinyl"}]}]}
        """#.utf8))
        let releases = try await service.searchMusicBrainzReleases(artist: "Simon & Garfunkel", album: "Bookends")
        let release = try XCTUnwrap(releases.first)
        XCTAssertEqual(release.artist, "Simon & Garfunkel")
        XCTAssertEqual(release.releaseGroupID, "rg-9")
        XCTAssertEqual(release.formats, ["12\" Vinyl", "12\" Vinyl"])
        XCTAssertEqual(release.format, "12\" Vinyl")
        XCTAssertEqual(release.mediaSummary, "2×12\" Vinyl")
        XCTAssertEqual(release.year, 1968)
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
