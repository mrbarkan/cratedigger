#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Canned-response tests for the two providers: the wire shapes are real
/// (trimmed) samples from each service, so a parsing regression shows up here
/// rather than as a mystery "no match" against a live server.
final class ReleaseMetadataProviderTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var requestedURLs: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let url = request.url { Self.requestedURLs.append(url) }
            guard let handler = Self.handler else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.requestedURLs = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func respond(_ bodies: [String: String]) {
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            let body = bodies.first { url.contains($0.key) }?.value ?? "{}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private let query = ReleaseQuery(
        artist: "New Order",
        album: "Technique",
        tracks: [QueryTrack(title: "Fine Time", trackNumber: 1, durationSeconds: 292)]
    )

    // MARK: - MusicBrainz

    private let musicBrainzSearch = """
    {"releases":[{
        "id":"mbid-technique",
        "title":"Technique",
        "date":"1989-01-30",
        "track-count":9,
        "artist-credit":[{"name":"New Order"}]
    }]}
    """

    private let musicBrainzDetail = """
    {"media":[
        {"position":1,"tracks":[
            {"position":1,"title":"Fine Time","length":292000,"artist-credit":[{"name":"New Order"}]},
            {"position":2,"title":"All the Way","length":203000}
        ]},
        {"position":2,"tracks":[
            {"position":1,"title":"Bonus Beat","length":180000}
        ]}
    ]}
    """

    func testMusicBrainzParsesReleaseAndTracks() async throws {
        respond(["/release/?": musicBrainzSearch, "/release/mbid-technique": musicBrainzDetail])
        let client = MusicBrainzReleaseClient(session: session)

        let candidates = try await client.searchReleases(query: query, detailLimit: 3)

        let release = try XCTUnwrap(candidates.first)
        XCTAssertEqual(release.source, .musicBrainz)
        XCTAssertEqual(release.title, "Technique")
        XCTAssertEqual(release.artist, "New Order")
        XCTAssertEqual(release.year, 1989)
        XCTAssertEqual(release.totalTracks, 9)
        XCTAssertEqual(release.totalDiscs, 2, "two media = a 2-disc release")
        XCTAssertEqual(release.tracks.count, 3)
        XCTAssertEqual(release.tracks[0].title, "Fine Time")
        XCTAssertEqual(try XCTUnwrap(release.tracks[0].durationSeconds), 292, accuracy: 0.001, "length is milliseconds")
        XCTAssertEqual(release.tracks[0].artist, "New Order")
        XCTAssertEqual(release.tracks[2].discNumber, 2)
    }

    func testMusicBrainzJoinsCollaborationCredits() async throws {
        let search = """
        {"releases":[{
            "id":"mbid-collab","title":"Collab","date":"2001",
            "artist-credit":[
                {"name":"Artist A","joinphrase":" feat. "},
                {"name":"Artist B"}
            ]
        }]}
        """
        respond(["/release/?": search, "/release/mbid-collab": "{\"media\":[]}"])

        let candidates = try await MusicBrainzReleaseClient(session: session)
            .searchReleases(query: query, detailLimit: 1)
        XCTAssertEqual(candidates.first?.artist, "Artist A feat. Artist B")
    }

    func testMusicBrainzSurvivesAFailedDetailLookup() async throws {
        // Search succeeds, detail 500s: the candidate is still offered, scored
        // on what the search alone knows.
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            let isSearch = url.contains("/release/?")
            let status = isSearch ? 200 : 500
            let body = isSearch ? self.musicBrainzSearch : "{}"
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let candidates = try await MusicBrainzReleaseClient(session: session)
            .searchReleases(query: query, detailLimit: 1)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].title, "Technique")
        XCTAssertTrue(candidates[0].tracks.isEmpty)
    }

    func testMusicBrainzEmptyResultsAreNotAnError() async throws {
        respond(["/release/?": "{\"releases\":[]}"])
        let candidates = try await MusicBrainzReleaseClient(session: session)
            .searchReleases(query: query, detailLimit: 3)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testMusicBrainzSearchURLQuotesTermsForLucene() throws {
        let url = try XCTUnwrap(MusicBrainzReleaseClient.searchURL(for: query))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryValue = try XCTUnwrap(components.queryItems?.first { $0.name == "query" }?.value)

        XCTAssertEqual(queryValue, "artist:\"New Order\" AND release:\"Technique\"")
    }

    func testMusicBrainzSearchURLEscapesQuotesInTitles() throws {
        let awkward = ReleaseQuery(artist: "Say \"Yes\"", album: "A \\ B")
        let url = try XCTUnwrap(MusicBrainzReleaseClient.searchURL(for: awkward))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryValue = try XCTUnwrap(components.queryItems?.first { $0.name == "query" }?.value)

        XCTAssertEqual(queryValue, #"artist:"Say \"Yes\"" AND release:"A \\ B""#)
    }

    func testMusicBrainzSearchesByTrackTitleWhenAlbumIsUnknown() throws {
        let untagged = ReleaseQuery(artist: "New Order", album: nil, tracks: [QueryTrack(title: "Fine Time")])
        let url = try XCTUnwrap(MusicBrainzReleaseClient.searchURL(for: untagged))
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value

        XCTAssertEqual(value, "artist:\"New Order\" AND recording:\"Fine Time\"")
    }

    func testMusicBrainzNeedsSomethingToSearchFor() {
        XCTAssertNil(MusicBrainzReleaseClient.searchURL(for: ReleaseQuery()))
    }

    // MARK: - iTunes

    private let iTunesSearch = """
    {"resultCount":1,"results":[{
        "wrapperType":"collection",
        "collectionId":123456,
        "collectionName":"Technique",
        "artistName":"New Order",
        "releaseDate":"1989-01-30T08:00:00Z",
        "primaryGenreName":"Alternative",
        "trackCount":9,
        "artworkUrl100":"https://example.com/a/100x100bb.jpg"
    }]}
    """

    private let iTunesLookup = """
    {"resultCount":3,"results":[
        {"wrapperType":"collection","collectionId":123456,"collectionName":"Technique"},
        {"wrapperType":"track","trackName":"Fine Time","trackNumber":1,"discNumber":1,
         "trackTimeMillis":292000,"artistName":"New Order"},
        {"wrapperType":"track","trackName":"All the Way","trackNumber":2,"discNumber":1,
         "trackTimeMillis":203000,"artistName":"New Order"}
    ]}
    """

    func testITunesParsesAlbumAndSongs() async throws {
        respond(["/search": iTunesSearch, "/lookup": iTunesLookup])
        let client = ITunesReleaseClient(session: session)

        let candidates = try await client.searchReleases(query: query, detailLimit: 3)

        let release = try XCTUnwrap(candidates.first)
        XCTAssertEqual(release.source, .iTunes)
        XCTAssertEqual(release.providerID, "123456")
        XCTAssertEqual(release.title, "Technique")
        XCTAssertEqual(release.artist, "New Order")
        XCTAssertEqual(release.year, 1989)
        XCTAssertEqual(release.genre, "Alternative")
        XCTAssertEqual(release.totalTracks, 9)
        XCTAssertNotNil(release.artworkURL)
        XCTAssertEqual(release.tracks.count, 2, "the collection row must not be read as a track")
        XCTAssertEqual(release.tracks[0].title, "Fine Time")
        XCTAssertEqual(try XCTUnwrap(release.tracks[0].durationSeconds), 292, accuracy: 0.001)
    }

    func testITunesEmptyResultsAreNotAnError() async throws {
        respond(["/search": "{\"resultCount\":0,\"results\":[]}"])
        let candidates = try await ITunesReleaseClient(session: session)
            .searchReleases(query: query, detailLimit: 3)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testITunesBadStatusThrows() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let client = ITunesReleaseClient(session: session)

        do {
            _ = try await client.searchReleases(query: query, detailLimit: 1)
            XCTFail("a 503 must surface as an error so the match service can log and move on")
        } catch {
            // expected — MetadataMatchService swallows this per-source.
        }
    }

    func testITunesMalformedJSONThrowsRatherThanCrashing() async {
        respond(["/search": "not json at all"])
        do {
            _ = try await ITunesReleaseClient(session: session).searchReleases(query: query, detailLimit: 1)
            XCTFail("malformed JSON must throw")
        } catch {
            // expected
        }
    }

    func testITunesSearchURLCombinesArtistAndAlbum() throws {
        let url = try XCTUnwrap(ITunesReleaseClient.searchURL(for: query))
        let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "term" }?.value
        XCTAssertEqual(term, "New Order Technique")
    }

    func testITunesFallsBackToATrackTitle() throws {
        let untagged = ReleaseQuery(tracks: [QueryTrack(title: "Fine Time")])
        let url = try XCTUnwrap(ITunesReleaseClient.searchURL(for: untagged))
        let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "term" }?.value
        XCTAssertEqual(term, "Fine Time")
    }
}
#endif
