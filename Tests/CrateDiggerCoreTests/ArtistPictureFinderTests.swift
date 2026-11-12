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
                        sources: [ArtistPictureSource]? = nil) -> ArtistPictureFinder {
        ArtistPictureFinder(sources: sources ?? [DeezerArtistSource(fetcher: fetcher, spacing: .zero, backoff: [])],
                            fetcher: fetcher, perArtist: perArtist, perRun: perRun)
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

    func testUnusableImageFallsToNextCandidate() async throws {
        deezer("Nirvana", [(415, "Nirvana", ["Nevermind"], FakePictureFetcher.jpeg(width: 120, height: 120)),
                           (416, "Nirvana", ["Nevermind"], Data("<html>gone</html>".utf8)),
                           (417, "Nirvana", ["Nevermind"], nil), // its picture answers 404
                           (418, "Nirvana", ["Nevermind"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Nirvana", ["Nevermind"], nil)])
        XCTAssertEqual(try XCTUnwrap(found(result.first)).candidate?.sourceID, "418")
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

    func testQuotaIsRetriedAfterABackOff() async throws {
        let quota = Data("{\"error\":{\"code\":4,\"message\":\"Quota limit exceeded\"}}".utf8)
        deezer("Daft Punk", [(27, "Daft Punk", ["Discovery"], FakePictureFetcher.jpeg())])
        let search = DeezerArtistParser.searchURL(name: "Daft Punk")
        let ok = try await fetcher.data(from: search)
        fetcher.answer(search, with: [.success(quota), .success(quota), .success(ok)])
        let source = DeezerArtistSource(fetcher: fetcher, spacing: .zero, backoff: [.milliseconds(1), .milliseconds(1)])

        let result = await finder(sources: [source]).find([("Daft Punk", ["Discovery"], nil)])
        XCTAssertNotNil(found(result.first))
        XCTAssertEqual(fetcher.requests.filter { $0 == search }.count, 4, "the probe above, then two quotas and a hit")
    }

    func testOneArtistsErrorDoesNotStopTheRun() async throws {
        fetcher.answer(DeezerArtistParser.searchURL(name: "Broken"), with: [.failure(ArtistPictureSourceError.http(500))])
        fetcher.answer(DeezerArtistParser.searchURL(name: "Garbled"), json: "<html>oops</html>")
        deezer("Air", [(3, "Air", ["Moon Safari"], FakePictureFetcher.jpeg())])

        let result = await finder().find([("Broken", [], nil), ("Garbled", [], nil), ("Air", ["Moon Safari"], nil)])

        XCTAssertEqual(result.map(\.name), ["Broken", "Garbled", "Air"])
        XCTAssertEqual(result.prefix(2).map(\.outcome), [.notFound, .notFound])
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
