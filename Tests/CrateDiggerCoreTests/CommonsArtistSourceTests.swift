import XCTest
@testable import CrateDiggerCore

/// Phase 2b: MusicBrainz artist search, its `wikidata` relation, property
/// P18, then the picture from Wikimedia Commons. JSON literals, never the network.
final class CommonsArtistSourceTests: XCTestCase {
    static let bjorkID = "87c5dedd-371d-4a53-9f7f-80522fb7f3cb"
    static let otherID = "11111111-2222-3333-4444-555555555555"

    static func searchJSON(_ rows: [(id: String, name: String, score: Int)]) -> String {
        let artists = rows.map { "{\"id\":\"\($0.id)\",\"type\":\"Person\",\"score\":\($0.score),\"name\":\"\($0.name)\",\"sort-name\":\"\($0.name)\"}" }
        return "{\"created\":\"2026-11-12T00:00:00.000Z\",\"count\":\(rows.count),\"offset\":0,\"artists\":[\(artists.joined(separator: ","))]}"
    }

    static func artistJSON(id: String, name: String, wikidata: String?, releaseGroups: [String]) -> String {
        var relations = ["{\"type\":\"official homepage\",\"url\":{\"resource\":\"https://bjork.com/\"}}"]
        if let wikidata {
            relations.append("{\"type\":\"wikidata\",\"url\":{\"resource\":\"https://www.wikidata.org/wiki/\(wikidata)\"}}")
        }
        let groups = releaseGroups.map { "{\"title\":\"\($0)\",\"primary-type\":\"Album\"}" }
        return "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"relations\":[\(relations.joined(separator: ","))],\"release-groups\":[\(groups.joined(separator: ","))]}"
    }

    static func entityJSON(id: String, image: String?) -> String {
        let p18 = image.map { ",\"P18\":[{\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P18\",\"datavalue\":{\"value\":\"\($0)\",\"type\":\"string\"}}}]" } ?? ""
        return "{\"entities\":{\"\(id)\":{\"id\":\"\(id)\",\"claims\":{\"P31\":[]\(p18)}}}}"
    }

    private var fetcher: FakePictureFetcher!

    override func setUp() {
        fetcher = FakePictureFetcher()
    }

    private func source(spacing: Duration = .zero) -> CommonsArtistSource {
        CommonsArtistSource(fetcher: fetcher, musicBrainzGate: MusicBrainzGate(interval: spacing))
    }

    static let imageInfoJSON = """
    {"batchcomplete":"","query":{"pages":{"123":{"pageid":123,"ns":6,"title":"File:Björk 2015.jpg","imageinfo":[{"extmetadata":{\
    "LicenseShortName":{"value":"CC BY-SA 4.0","source":"commons-desc-page"},\
    "Artist":{"value":"<a href=\\"//commons.wikimedia.org/wiki/User:Someone\\" title=\\"User:Someone\\">Someone &amp; Co</a>","source":"commons-desc-page"}}}]}}}}
    """

    private func answerBjork(wikidata: String? = "Q42", image: String? = "Björk 2015.jpg") {
        fetcher.answer(CommonsArtistSource.searchURL(name: "Björk"),
                       json: Self.searchJSON([(Self.bjorkID, "Björk", 100)]))
        fetcher.answer(CommonsArtistSource.artistURL(id: Self.bjorkID),
                       json: Self.artistJSON(id: Self.bjorkID, name: "Björk", wikidata: wikidata,
                                             releaseGroups: ["Debut", "Post", "Homogenic"]))
        fetcher.answer(CommonsArtistSource.releaseGroupsURL(artistID: Self.bjorkID),
                       json: ArtistInfoClientTests.browseJSON(["Debut", "Post", "Homogenic", "Vespertine"]))
        if let wikidata {
            fetcher.answer(CommonsArtistSource.entityURL(id: wikidata), json: Self.entityJSON(id: wikidata, image: image))
        }
        if let image {
            fetcher.answer(CommonsArtistSource.imageInfoURL(fileName: image), json: Self.imageInfoJSON)
        }
    }

    // MARK: Parser

    func testMusicBrainzSearchParsesTopArtists() throws {
        let data = Data(Self.searchJSON([(Self.bjorkID, "Björk", 100), (Self.otherID, "Bjork Band", 94)]).utf8)
        let artists = try CommonsArtistParser.musicBrainzArtists(data)
        XCTAssertEqual(artists.map(\.id), [Self.bjorkID, Self.otherID])
        XCTAssertEqual(artists.map(\.name), ["Björk", "Bjork Band"])
        XCTAssertEqual(artists.map(\.score), [100, 94])
    }

    func testLowScoreArtistsDropped() async throws {
        fetcher.answer(CommonsArtistSource.searchURL(name: "Björk"),
                       json: Self.searchJSON([(Self.otherID, "Björk Tribute", 89), (Self.bjorkID, "Björk", 100)]))
        fetcher.answer(CommonsArtistSource.artistURL(id: Self.bjorkID),
                       json: Self.artistJSON(id: Self.bjorkID, name: "Björk", wikidata: "Q42", releaseGroups: []))
        fetcher.answer(CommonsArtistSource.entityURL(id: "Q42"), json: Self.entityJSON(id: "Q42", image: "B.jpg"))

        let candidates = try await source().candidates(for: "Björk")
        XCTAssertEqual(candidates.map(\.sourceID), [Self.bjorkID])
        XCTAssertFalse(fetcher.requests.contains(CommonsArtistSource.artistURL(id: Self.otherID)))
    }

    func testOnlyTheTopThreeAreLookedUp() async throws {
        let rows = (0..<5).map { (id: "id-\($0)", name: "Björk", score: 100) }
        fetcher.answer(CommonsArtistSource.searchURL(name: "Björk"), json: Self.searchJSON(rows))
        for row in rows {
            fetcher.answer(CommonsArtistSource.artistURL(id: row.id),
                           json: Self.artistJSON(id: row.id, name: row.name, wikidata: nil, releaseGroups: []))
        }
        _ = try await source().candidates(for: "Björk")
        XCTAssertEqual(fetcher.requests.filter { $0.path.hasPrefix("/ws/2/artist/") }.count, 3)
    }

    func testWikidataRelationFound() throws {
        let data = Data(Self.artistJSON(id: Self.bjorkID, name: "Björk", wikidata: "Q42", releaseGroups: []).utf8)
        XCTAssertEqual(try CommonsArtistParser.wikidataID(fromArtist: data), "Q42")
        let odd = Data("{\"relations\":[{\"type\":\"wikidata\",\"url\":{\"resource\":\"https://www.wikidata.org/wiki/Special:Search\"}}]}".utf8)
        XCTAssertNil(try CommonsArtistParser.wikidataID(fromArtist: odd), "only a Q number is an entity")
    }

    func testNoWikidataRelationGivesNoCandidate() async throws {
        answerBjork(wikidata: nil)
        let candidates = try await source().candidates(for: "Björk")
        XCTAssertEqual(candidates, [])
        XCTAssertFalse(fetcher.requests.contains { $0.host == "www.wikidata.org" })
    }

    func testEntityWithoutP18GivesNoCandidate() async throws {
        answerBjork(image: nil)
        let candidates = try await source().candidates(for: "Björk")
        XCTAssertEqual(candidates, [])
        XCTAssertNil(try CommonsArtistParser.imageFileName(fromEntity: Data(Self.entityJSON(id: "Q42", image: nil).utf8),
                                                           id: "Q42"))
    }

    func testImageURLEncodesSpacesAndUnicode() {
        XCTAssertEqual(CommonsArtistParser.imageURL(fileName: "Björk 2015.jpg").absoluteString,
                       "https://commons.wikimedia.org/wiki/Special:FilePath/Bj%C3%B6rk_2015.jpg?width=800")
        XCTAssertEqual(CommonsArtistParser.imageURL(fileName: "AC/DC & Co?.png", width: 400).absoluteString,
                       "https://commons.wikimedia.org/wiki/Special:FilePath/AC%2FDC_%26_Co%3F.png?width=400")
    }

    /// Album titles are browsed only when the finder asks (for a name that
    /// matches), from the release-group browse, not the lookup's capped list.
    func testAlbumTitlesComeFromTheReleaseGroupBrowse() async throws {
        answerBjork()
        let candidates = try await source().candidates(for: "Björk")
        XCTAssertEqual(candidates, [ArtistPictureCandidate(
            name: "Björk", source: .commons, sourceID: Self.bjorkID,
            imageURL: CommonsArtistParser.imageURL(fileName: "Björk 2015.jpg"),
            credit: ArtistPictureCredit(fileName: "Björk 2015.jpg", licence: "CC BY-SA 4.0", author: "Someone & Co"))])
        let browse = CommonsArtistSource.releaseGroupsURL(artistID: Self.bjorkID)
        XCTAssertFalse(fetcher.requests.contains(browse), "nothing browsed before the finder asks")
        let titles = try await source().albumTitles(for: candidates[0])
        XCTAssertEqual(titles, ["Debut", "Post", "Homogenic", "Vespertine"])
        XCTAssertEqual(source().id, .commons)

        // Review I1: the matching album is the 40th, past the lookup's 25.
        var albums = (1...45).map { "Album \($0)" }
        albums[39] = "Biophilia"
        fetcher.answer(browse, json: ArtistInfoClientTests.browseJSON(albums))
        let many = try await source().albumTitles(for: candidates[0])
        XCTAssertEqual(many.count, 45)
        XCTAssertEqual(ArtistPictureMatcher.verdict(ArtistPictureCandidate(
            name: "Björk", source: .commons, sourceID: Self.bjorkID, imageURL: candidates[0].imageURL, albumTitles: many),
            name: "Björk", deviceAlbumTitles: ["Biophilia"]), .confident)
    }

    func testSpacingBetweenMusicBrainzCalls() async throws {
        answerBjork()
        _ = try await source(spacing: .milliseconds(50)).candidates(for: "Björk")
        let times = zip(fetcher.requests, fetcher.requestTimes).filter { $0.0.host == "musicbrainz.org" }.map(\.1)
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], .milliseconds(50))
    }

    /// Review M11: the file name stays even when Commons gives no licence.
    func testCreditFallsBackToTheFileName() async throws {
        answerBjork()
        fetcher.answer(CommonsArtistSource.imageInfoURL(fileName: "Björk 2015.jpg"),
                       with: [.failure(ArtistPictureSourceError.http(404))])
        let candidates = try await source().candidates(for: "Björk")
        XCTAssertEqual(candidates.first?.credit, ArtistPictureCredit(fileName: "Björk 2015.jpg"))
        XCTAssertEqual(CommonsArtistSource.imageInfoURL(fileName: "Björk 2015.jpg").absoluteString,
                       "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=extmetadata&titles=File%3ABj%C3%B6rk_2015.jpg")
    }

    /// Review I5: two sources (and anything else) waiting at one gate never
    /// send MusicBrainz two requests closer than its interval.
    func testTwoSourcesShareOneMusicBrainzGate() async throws {
        answerBjork()
        let gate = MusicBrainzGate(interval: .milliseconds(60))
        let first = CommonsArtistSource(fetcher: fetcher, musicBrainzGate: gate)
        let second = CommonsArtistSource(fetcher: fetcher, musicBrainzGate: gate)
        async let a = first.candidates(for: "Björk")
        async let b = second.candidates(for: "Björk")
        _ = try await (a, b)
        let times = zip(fetcher.requests, fetcher.requestTimes).filter { $0.0.host == "musicbrainz.org" }.map(\.1).sorted()
        XCTAssertEqual(times.count, 4)
        // Slots are 60 ms apart; a request is recorded when its task wakes, so allow for scheduling.
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, .milliseconds(30))
        }
        if let first = times.first, let last = times.last {
            XCTAssertGreaterThanOrEqual(last - first, .milliseconds(170))
        }
    }

    func test503IsRetriedOnce() async throws {
        answerBjork()
        let search = CommonsArtistSource.searchURL(name: "Björk")
        let ok = try await fetcher.data(from: search)
        fetcher.answer(search, with: [.failure(ArtistPictureSourceError.http(503)), .success(ok)])
        let retried = try await source().candidates(for: "Björk")
        XCTAssertEqual(retried.count, 1)

        fetcher.answer(search, with: [.failure(ArtistPictureSourceError.http(503))])
        do {
            _ = try await source().candidates(for: "Björk")
            XCTFail("a second 503 gives up")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .http(503))
        }
        // The probe, the 503 and its retry, then the two 503s.
        XCTAssertEqual(fetcher.requests.filter { $0 == search }.count, 5)
    }

    func testMalformedJSONThrowsMalformed() {
        for body in ["<html>busy</html>", "", "[]", "{\"artists\":{}}"] {
            XCTAssertThrowsError(try CommonsArtistParser.musicBrainzArtists(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
        }
        for body in ["<html>", "[]"] {
            XCTAssertThrowsError(try CommonsArtistParser.wikidataID(fromArtist: Data(body.utf8))) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
            XCTAssertThrowsError(try CommonsArtistParser.releaseGroupTitles(fromArtist: Data(body.utf8))) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
            XCTAssertThrowsError(try CommonsArtistParser.imageFileName(fromEntity: Data(body.utf8), id: "Q1")) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
        }
    }

    func testSearchURLQuotesTheNameAndCarriesNothingElse() throws {
        let url = CommonsArtistSource.searchURL(name: "Guns N' Roses \"Live\" & Co")
        XCTAssertEqual(url.host, "musicbrainz.org")
        XCTAssertEqual(url.path, "/ws/2/artist")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["query": "artist:\"Guns N' Roses \\\"Live\\\" & Co\"", "fmt": "json", "limit": "5"])
        XCTAssertEqual(CommonsArtistSource.artistURL(id: Self.bjorkID).absoluteString,
                       "https://musicbrainz.org/ws/2/artist/\(Self.bjorkID)?inc=url-rels&fmt=json")
        XCTAssertEqual(CommonsArtistSource.releaseGroupsURL(artistID: Self.bjorkID).absoluteString,
                       "https://musicbrainz.org/ws/2/release-group?artist=\(Self.bjorkID)&type=album%7Cep&limit=100&fmt=json")
        XCTAssertEqual(CommonsArtistSource.entityURL(id: "Q42").absoluteString,
                       "https://www.wikidata.org/wiki/Special:EntityData/Q42.json")
    }
}
