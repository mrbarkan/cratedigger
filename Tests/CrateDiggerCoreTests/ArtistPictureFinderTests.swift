import XCTest
@testable import CrateDiggerCore

/// The finder: the library's own picture first, then each source in order,
/// a picture taken only on a confident match. Never the network in a test.
final class ArtistPictureFinderTests: XCTestCase {
    typealias Request = (name: String, deviceAlbumTitles: [String], libraryPicture: URL?)

    static let imageHost = "e-cdns-images.dzcdn.net"

    private var fetcher: FakePictureFetcher!
    private var scratch: URL!

    override func setUpWithError() throws {
        fetcher = FakePictureFetcher()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPictureFinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    private func imageURL(_ id: Int) -> URL {
        URL(string: "https://\(Self.imageHost)/images/artist/\(String(repeating: "\(id % 10)", count: 32))/1000x1000-000000-80-0-0.jpg")!
    }

    /// Deezer answers `name` with these artists (id, name), each with its albums and picture.
    private func deezer(_ name: String, _ artists: [(id: Int, name: String, albums: [String], image: Data?)]) {
        let rows = artists.map { DeezerArtistParserTests.artistJSON(id: $0.id, name: $0.name,
                                                                    xl: imageURL($0.id).absoluteString) }
        fetcher.answer(DeezerArtistParser.searchURL(name: name),
                       json: "{\"data\":[\(rows.joined(separator: ","))],\"total\":\(rows.count)}")
        for artist in artists {
            let albums = artist.albums.map { "{\"id\":1,\"title\":\"\($0)\"}" }.joined(separator: ",")
            fetcher.answer(DeezerArtistParser.albumsURL(artistID: String(artist.id)), json: "{\"data\":[\(albums)]}")
            if let image = artist.image { fetcher.answer(imageURL(artist.id), data: image) }
        }
    }

    private func finder(perArtist: Duration = .seconds(8), perRun: Duration = .seconds(120),
                        sources: [ArtistPictureSource]? = nil, quotaBackoff: [Duration] = []) -> ArtistPictureFinder {
        ArtistPictureFinder(sources: sources ?? [DeezerArtistSource(fetcher: fetcher, spacing: .zero)],
                            fetcher: fetcher, perArtist: perArtist, perRun: perRun, quotaBackoff: quotaBackoff)
    }

    /// A second source with fixed candidates.
    private struct FixedSource: ArtistPictureSource {
        let id: ArtistPictureSourceID
        let offered: [ArtistPictureCandidate]
        func candidates(for name: String) async throws -> [ArtistPictureCandidate] { offered }
        func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] { candidate.albumTitles }
    }

    private func outcome(_ finding: ArtistPictureFinding?) -> ArtistPictureFinding.Outcome? { finding?.outcome }

    private func isFailed(_ finding: ArtistPictureFinding?) -> Bool {
        if case .failed? = finding?.outcome { return true }
        return false
    }

    private func found(_ finding: ArtistPictureFinding?, file: StaticString = #filePath, line: UInt = #line)
        -> (prepared: Data, candidate: ArtistPictureCandidate?, source: ArtistPictureSourceID)? {
        guard case let .found(prepared, candidate, source)? = finding?.outcome else {
            XCTFail("expected found, got \(String(describing: finding?.outcome))", file: file, line: line)
            return nil
        }
        return (prepared, candidate, source)
    }

    private func isPreparedJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xff, 0xd8]) && data.count <= ArtistPictureImage.maximumBytes
    }

    // MARK: Tests

    func testLibraryPictureWinsWithoutNetwork() async throws {
        let picture = scratch.appendingPathComponent("artist.jpg")
        try FakePictureFetcher.jpeg().write(to: picture)
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Daft Punk", ["Discovery"], picture)])

        XCTAssertEqual(result.map(\.name), ["Daft Punk"])
        let hit = try XCTUnwrap(found(result.first))
        XCTAssertEqual(hit.source, .libraryFolder)
        XCTAssertNil(hit.candidate)
        XCTAssertTrue(isPreparedJPEG(hit.prepared))
        XCTAssertEqual(fetcher.requests, [], "the library's own picture needs no request")
    }

    func testUnusableLibraryPictureFallsThroughToTheSources() async throws {
        let picture = scratch.appendingPathComponent("artist.jpg")
        try FakePictureFetcher.jpeg(width: 120, height: 120).write(to: picture)
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Daft Punk", ["Discovery"], picture)])
        XCTAssertEqual(try XCTUnwrap(found(result.first)).source, .deezer)
    }

    func testConfidentCandidateIsFetchedAndPrepared() async throws {
        deezer("Daft Punk", [(27, "Daft Punk", ["Homework", "Discovery"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Daft Punk", ["Discovery (2001)"], nil)])

        let hit = try XCTUnwrap(found(result.first))
        XCTAssertEqual(hit.source, .deezer)
        XCTAssertEqual(hit.candidate?.sourceID, "27")
        XCTAssertEqual(hit.candidate?.albumTitles, ["Homework", "Discovery"])
        XCTAssertTrue(isPreparedJPEG(hit.prepared))
        XCTAssertEqual(fetcher.requests, [DeezerArtistParser.searchURL(name: "Daft Punk"),
                                          DeezerArtistParser.albumsURL(artistID: "27"), imageURL(27)])
    }

    func testUncertainWhenNoAlbumMatches() async throws {
        deezer("Nirvana", [(415, "Nirvana", ["Bleach"], FakePictureFetcher.jpeg()),
                           (9001, "Nirvana", ["All of Us"], FakePictureFetcher.jpeg()),
                           (77, "Nirvana Tribute", ["Nevermind"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Nirvana", ["Nevermind"], nil)])

        guard case .uncertain(let candidates)? = result.first?.outcome else {
            return XCTFail("expected uncertain, got \(String(describing: result.first?.outcome))")
        }
        XCTAssertEqual(candidates.map(\.sourceID), ["415", "9001"], "only name matches, albums filled in")
        XCTAssertEqual(candidates.map(\.albumTitles), [["Bleach"], ["All of Us"]])
        XCTAssertFalse(fetcher.requests.contains { $0.host == Self.imageHost }, "no image is fetched for a guess")
    }

    func testUncertainKeepsAtMostFive() async throws {
        deezer("Nirvana", (1...7).map { ($0, "Nirvana", ["Album \($0)"], nil) })
        let result = await finder().find([("Nirvana", ["Nevermind"], nil)])
        guard case .uncertain(let candidates)? = result.first?.outcome else { return XCTFail("expected uncertain") }
        XCTAssertEqual(candidates.count, 5)
    }

    func testNotFoundWhenNoCandidates() async {
        fetcher.answer(DeezerArtistParser.searchURL(name: "Nobody"), json: "{\"data\":[],\"total\":0}")
        let result = await finder().find([("Nobody", ["Nothing"], nil)])
        XCTAssertEqual(result.map(\.outcome), [.notFound])
    }

    /// Review I4: two candidates both confirmed by an album are two acts
    /// that look right; neither is taken without the owner.
    func testTwoConfidentCandidatesAreHeld() async throws {
        deezer("Nirvana", [(415, "Nirvana", ["Nevermind"], FakePictureFetcher.jpeg()),
                           (418, "Nirvana", ["Nevermind"], FakePictureFetcher.jpeg())])
        let result = await finder().find([("Nirvana", ["Nevermind"], nil)])
        guard case .uncertain(let held)? = outcome(result.first) else { return XCTFail("expected held") }
        XCTAssertEqual(held.map(\.sourceID), ["415", "418"])
        XCTAssertFalse(fetcher.requests.contains { $0.host == Self.imageHost })
    }

    /// Review I4: two acts named Boston. Only the one sharing a telling album
    /// is taken; a shared self-titled album proves nothing.
    func testTwoActsNamedBoston() async throws {
        deezer("Boston", [(1, "Boston", ["Boston", "Don't Look Back", "Third Stage"], FakePictureFetcher.jpeg()),
                          (2, "Boston", ["Boston", "Live", "Greatest Hits"], FakePictureFetcher.jpeg())])
        let sure = await finder().find([("Boston", ["Boston", "Don't Look Back (Remastered)"], nil)])
        XCTAssertEqual(try XCTUnwrap(found(sure.first)).candidate?.sourceID, "1")

        let onlyGeneric = await finder().find([("Boston", ["Boston", "Live", "Greatest Hits"], nil)])
        guard case .uncertain(let held)? = outcome(onlyGeneric.first) else { return XCTFail("expected held") }
        XCTAssertEqual(Set(held.map(\.sourceID)), ["1", "2"])
    }

    /// Review I4: an artist whose only album is self-titled is held, not accepted.
    func testSelfTitledOnlyIsHeld() async throws {
        deezer("Weezer", [(9, "Weezer", ["Weezer", "Pinkerton"], FakePictureFetcher.jpeg())])
        let result = await finder().find([("Weezer", ["Weezer (Blue Album)"], nil)])
        guard case .uncertain(let held)? = outcome(result.first) else { return XCTFail("expected held") }
        XCTAssertEqual(held.map(\.sourceID), ["9"])
    }

    /// The one confident candidate's picture is unusable: held, and the next source is asked.
    func testUnusableImageFallsToTheNextSource() async throws {
        deezer("Nirvana", [(415, "Nirvana", ["Nevermind"], FakePictureFetcher.jpeg(width: 120, height: 120))])
        let commonsURL = URL(string: "https://upload.wikimedia.org/nirvana.jpg")!
        fetcher.answer(commonsURL, data: FakePictureFetcher.jpeg())
        let second = FixedSource(id: .commons, offered: [ArtistPictureCandidate(
            name: "Nirvana", source: .commons, sourceID: "mb-1", imageURL: commonsURL, albumTitles: ["Nevermind"])])
        let result = await finder(sources: [DeezerArtistSource(fetcher: fetcher, spacing: .zero), second])
            .find([("Nirvana", ["Nevermind"], nil)])
        let hit = try XCTUnwrap(found(result.first))
        XCTAssertEqual(hit.source, .commons)

        let alone = await finder().find([("Nirvana", ["Nevermind"], nil)])
        guard case .uncertain? = outcome(alone.first) else { return XCTFail("an unusable picture is held, not found") }
    }

    func testQuotaStopsTheRunAndKeepsEarlierResults() async throws {
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])
        fetcher.answer(DeezerArtistParser.searchURL(name: "Justice"),
                       json: "{\"error\":{\"type\":\"Exception\",\"message\":\"Quota limit exceeded\",\"code\":4}}")
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Daft Punk", ["Discovery"], nil), ("Justice", ["Cross"], nil),
                                          ("Air", ["Moon Safari"], nil)])

        XCTAssertEqual(result.map(\.name), ["Daft Punk"], "the quota-hit artist and the rest wait for another run")
        XCTAssertNotNil(found(result.first))
        XCTAssertFalse(fetcher.requests.contains(DeezerArtistParser.searchURL(name: "Air")))
    }

    /// Review I6: the quota surfaces at once and the run pauses, outside the
    /// artist's own budget (the pauses here are longer than that budget).
    func testQuotaBacksOffForTheRunOutsideTheArtistTimer() async throws {
        let quota = Data("{\"error\":{\"code\":4,\"message\":\"Quota limit exceeded\"}}".utf8)
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])
        let search = DeezerArtistParser.searchURL(name: "Daft Punk")
        let ok = try await fetcher.data(from: search)
        fetcher.answer(search, with: [.success(quota), .success(quota), .success(ok)])

        let started = ContinuousClock.now
        let result = await finder(perArtist: .milliseconds(150), quotaBackoff: [.milliseconds(200), .milliseconds(200)])
            .find([("Daft Punk", ["Discovery"], nil)])
        XCTAssertNotNil(found(result.first))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(400))
        let times = zip(fetcher.requests, fetcher.requestTimes).filter { $0.0 == search }.map(\.1).suffix(3)
        XCTAssertEqual(times.count, 3, "two quotas, then the answer")
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, .milliseconds(200), "no request during a pause")
        }
    }

    func testQuotaPastTheLastPauseStopsTheRun() async {
        let quota = "{\"error\":{\"code\":4}}"
        fetcher.answer(DeezerArtistParser.searchURL(name: "Justice"), json: quota)
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])
        let result = await finder(quotaBackoff: [.milliseconds(5), .milliseconds(5)])
            .find([("Justice", ["Cross"], nil), ("Air", ["Moon Safari"], nil)])
        XCTAssertEqual(result.map(\.name), [])
        XCTAssertEqual(fetcher.requests, Array(repeating: DeezerArtistParser.searchURL(name: "Justice"), count: 3))
    }

    /// Review I3: offline, nothing is learned, so nothing may be stored, and
    /// the run stops instead of failing every remaining name.
    func testOfflineRunStopsAndStoresNothing() async {
        fetcher.answer(DeezerArtistParser.searchURL(name: "Daft Punk"),
                       with: [.failure(URLError(.notConnectedToInternet))])
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])
        let result = await finder().find([("Daft Punk", ["Discovery"], nil), ("Air", ["Moon Safari"], nil)])
        XCTAssertEqual(result.map(\.name), ["Daft Punk"])
        XCTAssertTrue(isFailed(result.first))
        XCTAssertFalse(result.contains { $0.outcome.isStorable }, "an offline run stores nothing")
        XCTAssertFalse(fetcher.requests.contains(DeezerArtistParser.searchURL(name: "Air")))
    }

    func testServerErrorStopsTheRun() async {
        fetcher.answer(DeezerArtistParser.searchURL(name: "Broken"), with: [.failure(ArtistPictureSourceError.http(503))])
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])
        let result = await finder().find([("Broken", [], nil), ("Air", ["Moon Safari"], nil)])
        XCTAssertEqual(result.map(\.name), ["Broken"])
        XCTAssertTrue(isFailed(result.first))
    }

    /// Review I3: a broken answer or a picture that would not download is a
    /// failure for that name, never "not found", and the run goes on.
    func testOneArtistsFailureIsNotNotFound() async throws {
        fetcher.answer(DeezerArtistParser.searchURL(name: "Garbled"), json: "<html>oops</html>")
        deezer("Gone", [(5, "Gone", ["Away"], nil)]) // its picture answers 404
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Garbled", [], nil), ("Gone", ["Away"], nil), ("Air", ["Moon Safari"], nil)])

        XCTAssertEqual(result.map(\.name), ["Garbled", "Gone", "Air"])
        XCTAssertTrue(isFailed(result[0]))
        XCTAssertTrue(isFailed(result[1]))
        XCTAssertFalse(result[0].outcome.isStorable)
        XCTAssertNotNil(found(result.last))
    }

    func testRunBudgetStopsEarly() async {
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])
        let result = await finder(perRun: .zero).find([("Air", ["Moon Safari"], nil)])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(fetcher.requests, [])
    }

    /// An artist that runs past its own budget is left for a later run, not
    /// recorded as having no picture.
    func testSlowArtistIsLeftForLater() async throws {
        struct Slow: ArtistPictureSource {
            var id: ArtistPictureSourceID { .deezer }
            func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
                try await Task.sleep(for: .seconds(30))
                return []
            }
            func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] { [] }
        }
        let started = ContinuousClock.now
        let result = await finder(perArtist: .milliseconds(50), sources: [Slow()]).find([("Air", [], nil)])
        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the slow source was cancelled")
    }

    func testRequestsCarryOnlyTheArtistName() async throws {
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])
        deezer("Björk", [(5, "Björk", ["Post"], FakePictureFetcher.jpeg())])
        fetcher.answer(DeezerArtistParser.searchURL(name: "AC/DC"), json: "{\"data\":[]}")

        _ = await finder().find([("Daft Punk", ["Discovery"], nil), ("Björk", ["Homogenic"], nil),
                                 ("AC/DC", ["Back in Black"], nil)])

        let home = URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent
        XCTAssertFalse(fetcher.requests.isEmpty)
        for url in fetcher.requests {
            XCTAssertTrue(["api.deezer.com", Self.imageHost].contains(url.host ?? ""), url.absoluteString)
            let text = url.absoluteString
            for secret in [home, "/Volumes", "IPOD", "Homogenic", "Back%20in%20Black"] where !secret.isEmpty {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(secret), "\(text) carries \(secret)")
            }
        }
    }

    /// Review M6: only the sources' own hosts, over HTTPS, by name.
    func testFetcherOnlyFetchesTheSourcesOwnHosts() async {
        for allowed in ["https://api.deezer.com/search/artist", "https://e-cdns-images.dzcdn.net/images/artist/x.jpg",
                        "https://musicbrainz.org/ws/2/artist", "https://upload.wikimedia.org/a.jpg"] {
            XCTAssertTrue(URLSessionPictureFetcher.isAllowed(URL(string: allowed)), allowed)
        }
        for refused in ["http://api.deezer.com/search/artist", "https://evil.example/x.jpg", "https://192.168.1.10/x.jpg",
                        "https://127.0.0.1/x.jpg", "https://dzcdn.net.evil.example/x.jpg", "https://api.deezer.com:8443/x",
                        "https://user@api.deezer.com/x", "file:///etc/passwd"] {
            XCTAssertFalse(URLSessionPictureFetcher.isAllowed(URL(string: refused)), refused)
        }
        do {
            _ = try await URLSessionPictureFetcher().data(from: URL(string: "https://evil.example/x.jpg")!)
            XCTFail("an unknown host is refused before any request")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .refusedURL)
        }
    }

    /// Review M5 and M6, through a stub protocol (no network): a body is cut
    /// off past 32 MB as it arrives, and a redirect off the allowed hosts is not followed.
    func testFetcherStopsAtTheCapAndRefusesForeignRedirects() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let fetcher = URLSessionPictureFetcher(session: URLSession(configuration: configuration))
        do {
            _ = try await fetcher.data(from: URL(string: "https://api.deezer.com/huge")!)
            XCTFail("a body past the cap is refused")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .malformed)
        }
        XCTAssertLessThan(StubProtocol.servedBytes, 40 * 1024 * 1024, "reading stopped near the cap")
        do {
            _ = try await fetcher.data(from: URL(string: "https://e-cdns-images.dzcdn.net/redirect")!)
            XCTFail("a redirect to another host is not followed")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .http(302))
        }
        let small = try? await fetcher.data(from: URL(string: "https://api.deezer.com/small")!)
        XCTAssertEqual(small, Data("ok".utf8))
    }

    func testFetcherSendsAGenericClientNameAndNoCookies() {
        let session = URLSessionPictureFetcher.makeSession()
        let configuration = session.configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        let request = URLSessionPictureFetcher.request(for: URL(string: "https://api.deezer.com/search/artist")!)
        let agent = try? XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent?.hasPrefix("CrateDigger") == true)
        XCTAssertEqual(request.allHTTPHeaderFields?.keys.sorted(), ["Accept", "User-Agent"])
    }
}

/// Serves fixed answers for the fetcher tests, so nothing reaches the network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var servedBytes = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        switch url.path {
        case "/huge":
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: [:])!,
                               cacheStoragePolicy: .notAllowed)
            let chunk = Data(count: 1024 * 1024)
            Self.servedBytes = 0
            for _ in 0..<36 {
                Self.servedBytes += chunk.count
                client.urlProtocol(self, didLoad: chunk)
            }
            client.urlProtocolDidFinishLoading(self)
        case "/redirect":
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": "https://evil.example/x.jpg"])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.example/x.jpg")!),
                               redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        default:
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: [:])!,
                               cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("ok".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
