import XCTest
@testable import CrateDiggerCore

/// The artist info client against a fake fetcher: which URLs it asks for,
/// through which gate lane, and what a failure becomes. Never the network.
final class ArtistInfoClientTests: XCTestCase {
    static let massiveID = ArtistInfoParsersTests.massiveID

    static let searchJSON = """
    {"created":"2026-11-12T00:00:00.000Z","count":1,"offset":0,"artists":[\
    {"id":"10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8","type":"Group","score":100,"name":"Massive Attack",\
    "sort-name":"Massive Attack","country":"GB","area":{"id":"a","type":"Country","name":"United Kingdom"},\
    "begin-area":{"id":"b","type":"City","name":"Bristol"},"life-span":{"begin":"1988","ended":null}}]}
    """

    private var fetcher: FakePictureFetcher!

    override func setUp() {
        fetcher = FakePictureFetcher()
    }

    private func client(_ gate: MusicBrainzGate = MusicBrainzGate(interval: .zero)) -> ArtistInfoClient {
        ArtistInfoClient(fetcher: fetcher, gate: gate, wikimediaSpacing: .zero)
    }

    /// A `/ws/2/release-group?artist=…` browse answer.
    static func browseJSON(_ titles: [String]) -> String {
        let groups = titles.enumerated().map { "{\"id\":\"rg\($0.offset)\",\"title\":\"\($0.element)\",\"primary-type\":\"Album\",\"secondary-types\":[],\"first-release-date\":\"1991\",\"disambiguation\":\"\"}" }
        return "{\"release-group-count\":\(titles.count),\"release-group-offset\":0,\"release-groups\":[\(groups.joined(separator: ","))]}"
    }

    private func answerMassiveAttack(sitelinks: [String: String] = ["enwiki": "Massive Attack"]) {
        fetcher.answer(ArtistInfoClient.searchURL(name: "Massive Attack"), json: Self.searchJSON)
        fetcher.answer(ArtistInfoClient.detailURL(musicBrainzID: Self.massiveID), json: ArtistInfoParsersTests.massiveDetail)
        fetcher.answer(CommonsArtistSource.releaseGroupsURL(artistID: Self.massiveID),
                       json: Self.browseJSON(["Blue Lines", "Protection", "Mezzanine", "100th Window", "Heligoland"]))
        fetcher.answer(ArtistInfoClient.entityURL(wikidataID: "Q11895"),
                       json: ArtistInfoParsersTests.entityJSON(id: "Q11895", sitelinks: sitelinks))
        fetcher.answer(ArtistInfoClient.summaryURL(language: "en", title: "Massive Attack")!,
                       json: ArtistInfoParsersTests.summaryJSON)
    }

    func testURLs() {
        XCTAssertEqual(ArtistInfoClient.searchURL(name: "AC/DC & \"Friends\"").absoluteString,
                       "https://musicbrainz.org/ws/2/artist?query=artist%3A%22AC%2FDC%20%26%20%5C%22Friends%5C%22%22&fmt=json&limit=10")
        XCTAssertEqual(ArtistInfoClient.detailURL(musicBrainzID: Self.massiveID).absoluteString,
                       "https://musicbrainz.org/ws/2/artist/\(Self.massiveID)?inc=url-rels+artist-rels+genres&fmt=json")
        XCTAssertEqual(CommonsArtistSource.releaseGroupsURL(artistID: Self.massiveID).absoluteString,
                       "https://musicbrainz.org/ws/2/release-group?artist=\(Self.massiveID)&type=album%7Cep&limit=100&fmt=json")
        XCTAssertEqual(ArtistInfoClient.summaryURL(language: "pt", title: "Massive Attack (banda)")?.absoluteString,
                       "https://pt.wikipedia.org/api/rest_v1/page/summary/Massive_Attack_%28banda%29")
        XCTAssertEqual(ArtistInfoClient.summaryURL(language: "en", title: "AC/DC")?.absoluteString,
                       "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC")
        // A language that would not make a host name is never asked for.
        XCTAssertNil(ArtistInfoClient.summaryURL(language: "evil.example/x", title: "X"))
        XCTAssertNil(ArtistInfoClient.summaryURL(language: "", title: "X"))
    }

    func testFullLookup() async throws {
        answerMassiveAttack()
        let client = client()
        let candidates = try await client.candidates(for: "Massive Attack", lane: .foreground)
        XCTAssertEqual(candidates.map(\.musicBrainzID), [Self.massiveID])
        let detail = try await client.detail(musicBrainzID: Self.massiveID, lane: .foreground)
        XCTAssertEqual(detail.wikidataID, "Q11895")
        XCTAssertEqual(detail.facts.kind, "Group")
        XCTAssertEqual(detail.releaseGroupTitles, ["Blue Lines", "Protection", "Mezzanine", "100th Window", "Heligoland"])
        let bio = try await client.bio(wikidataID: "Q11895", preferredLanguages: ["pt-BR", "en-GB"])
        XCTAssertEqual(bio?.pageURL, URL(string: "https://en.wikipedia.org/wiki/Massive_Attack"))
        XCTAssertEqual(bio?.extract.hasPrefix("Massive Attack are an English trip hop group"), true)
    }

    func testPreferredLanguageWikipediaIsAsked() async throws {
        answerMassiveAttack(sitelinks: ["enwiki": "Massive Attack", "ptwiki": "Massive Attack (banda)"])
        let pt = try XCTUnwrap(ArtistInfoClient.summaryURL(language: "pt", title: "Massive Attack (banda)"))
        fetcher.answer(pt, json: ArtistInfoParsersTests.summaryJSON.replacingOccurrences(
            of: "https://en.wikipedia.org/wiki/Massive_Attack\"", with: "https://pt.wikipedia.org/wiki/Massive_Attack_(banda)\""))
        let bio = try await client().bio(wikidataID: "Q11895", preferredLanguages: ["pt-BR", "en"])
        XCTAssertEqual(bio?.pageURL, URL(string: "https://pt.wikipedia.org/wiki/Massive_Attack_(banda)"))
        XCTAssertTrue(fetcher.requests.contains(pt))
        XCTAssertFalse(fetcher.requests.contains(ArtistInfoClient.summaryURL(language: "en", title: "Massive Attack")!))
    }

    func testMissingArticleOrItemIsNoBio() async throws {
        // No Wikipedia sitelink at all.
        answerMassiveAttack(sitelinks: ["commonswiki": "Category:Massive Attack"])
        let none = try await client().bio(wikidataID: "Q11895", preferredLanguages: ["en"])
        XCTAssertNil(none)
        // A sitelink whose page 404s (the fake answers 404 to anything unknown).
        fetcher.answer(ArtistInfoClient.entityURL(wikidataID: "Q11895"),
                       json: ArtistInfoParsersTests.entityJSON(id: "Q11895", sitelinks: ["enwiki": "Gone Page"]))
        let gone = try await client().bio(wikidataID: "Q11895", preferredLanguages: ["en"])
        XCTAssertNil(gone)
        // An item since deleted.
        let deleted = try await client().bio(wikidataID: "Q999", preferredLanguages: ["en"])
        XCTAssertNil(deleted)
        // Not a Wikidata id: nothing is asked.
        let before = fetcher.requests.count
        let bogus = try await client().bio(wikidataID: "../x", preferredLanguages: ["en"])
        XCTAssertNil(bogus)
        XCTAssertEqual(fetcher.requests.count, before)
    }

    func testEveryMusicBrainzCallWaitsOnTheGateInItsLane() async throws {
        answerMassiveAttack()
        let gate = MusicBrainzGate(interval: .zero)
        let client = client(gate)
        _ = try await client.candidates(for: "Massive Attack", lane: .background)
        _ = try await client.detail(musicBrainzID: Self.massiveID, lane: .background)
        var issued = await gate.issued
        XCTAssertEqual(issued, [.background: 3])
        _ = try await client.candidates(for: "Massive Attack", lane: .foreground)
        _ = try await client.detail(musicBrainzID: Self.massiveID, lane: .foreground)
        issued = await gate.issued
        XCTAssertEqual(issued, [.background: 3, .foreground: 3])
        // Wikidata and Wikipedia are not MusicBrainz: they never take a slot.
        _ = try await client.bio(wikidataID: "Q11895", preferredLanguages: ["en"])
        issued = await gate.issued
        XCTAssertEqual(issued, [.background: 3, .foreground: 3])
        let musicBrainzRequests = fetcher.requests.filter { $0.host == "musicbrainz.org" }.count
        XCTAssertEqual(musicBrainzRequests, 6)
    }

    func testOnlyNamesAndIDsLeaveTheMachine() async throws {
        answerMassiveAttack()
        let client = client()
        _ = try await client.candidates(for: "Massive Attack", lane: .background)
        _ = try await client.detail(musicBrainzID: Self.massiveID, lane: .background)
        _ = try await client.bio(wikidataID: "Q11895", preferredLanguages: ["en"])
        XCTAssertEqual(fetcher.requests.count, 5)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in fetcher.requests {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(URLSessionPictureFetcher.isAllowed(url), url.absoluteString)
            let text = url.absoluteString
            // Only the name, the MusicBrainz id, the Wikidata id and the article title.
            let carries = [ArtistPictureURLText.encoded("Massive Attack"), Self.massiveID, "Q11895", "Massive_Attack"]
            XCTAssertTrue(carries.contains { text.contains($0) }, text)
            for secret in [home, "/Volumes", "Mezzanine", "Blue%20Lines", "Users"] where !secret.isEmpty {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(secret), "\(text) carries \(secret)")
            }
        }
    }

    /// Review I1: an artist lookup lists at most 25 release groups, singles
    /// included, so a prolific act's albums can fall outside it. The browse
    /// of albums and EPs finds the 40th, and that is what confirms.
    func testReleaseGroupsComeFromTheBrowseNotTheLookupsCappedList() async throws {
        let id = "prolific"
        let capped = (1...25).map { "{\"id\":\"s\($0)\",\"title\":\"Single \($0)\",\"primary-type\":\"Single\"}" }
        fetcher.answer(ArtistInfoClient.detailURL(musicBrainzID: id),
                       json: "{\"id\":\"\(id)\",\"name\":\"Air\",\"type\":\"Group\",\"relations\":[],\"release-groups\":[\(capped.joined(separator: ","))]}")
        var albums = (1...45).map { "Album \($0)" }
        albums[39] = "Moon Safari"
        fetcher.answer(CommonsArtistSource.releaseGroupsURL(artistID: id), json: Self.browseJSON(albums))

        let detail = try await client().detail(musicBrainzID: id, lane: .background)
        XCTAssertEqual(detail.releaseGroupTitles.count, 45)
        XCTAssertEqual(detail.releaseGroupTitles[39], "Moon Safari")
        XCTAssertEqual(ArtistIdentityMatcher.decide(
            name: "Air", libraryAlbumTitles: ["Moon Safari"],
            candidates: [(ArtistIdentityCandidate(musicBrainzID: id, name: "Air"), releaseGroupTitles: detail.releaseGroupTitles)],
            rejected: []), .confirmed(musicBrainzID: id, wikidataID: nil))
    }

    func testServerErrorIsNotNotFound() async {
        let search = ArtistInfoClient.searchURL(name: "Massive Attack")
        for failure: ArtistPictureSourceError in [.http(500), .http(503), .http(429), .transport("offline")] {
            fetcher.answer(search, with: [.failure(failure)])
            do {
                let found = try await client().candidates(for: "Massive Attack", lane: .background)
                XCTFail("\(failure) gave \(found), as if nobody were found")
            } catch {
                let read = error as? ArtistPictureSourceError
                XCTAssertEqual(read, failure)
                XCTAssertEqual(read?.stopsTheRun, true)
            }
        }
        fetcher.answer(ArtistInfoClient.detailURL(musicBrainzID: Self.massiveID), with: [.failure(ArtistPictureSourceError.http(502))])
        do {
            _ = try await client().detail(musicBrainzID: Self.massiveID, lane: .background)
            XCTFail("a 502 is thrown")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .http(502))
        }
        // A Wikimedia outage is thrown too, not read as "no bio".
        fetcher.answer(ArtistInfoClient.entityURL(wikidataID: "Q11895"), with: [.failure(ArtistPictureSourceError.http(500))])
        do {
            _ = try await client().bio(wikidataID: "Q11895", preferredLanguages: ["en"])
            XCTFail("a 500 is thrown")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .http(500))
        }
    }

    func test503IsRetriedOnceAfterTheNextSlot() async throws {
        let search = ArtistInfoClient.searchURL(name: "Massive Attack")
        fetcher.answer(search, with: [.failure(ArtistPictureSourceError.http(503)), .success(Data(Self.searchJSON.utf8))])
        let gate = MusicBrainzGate(interval: .zero)
        let found = try await client(gate).candidates(for: "Massive Attack", lane: .background)
        XCTAssertEqual(found.count, 1)
        let issued = await gate.issued
        XCTAssertEqual(issued, [.background: 2])
    }

    func testFetcherAllowsWikipediaHostsOnly() {
        for allowed in ["https://en.wikipedia.org/api/rest_v1/page/summary/X", "https://pt.wikipedia.org/wiki/X",
                        "https://zh-min-nan.wikipedia.org/wiki/X", "https://en.wikipedia.org:443/wiki/X"] {
            XCTAssertTrue(URLSessionPictureFetcher.isAllowed(URL(string: allowed)), allowed)
        }
        for refused in ["http://en.wikipedia.org/wiki/X", "https://en.wikipedia.org:8443/wiki/X",
                        "https://wikipedia.org.evil.example/x", "https://evilwikipedia.org/x",
                        "https://en.wikipedia.org.evil.example/x", "https://user@en.wikipedia.org/x"] {
            XCTAssertFalse(URLSessionPictureFetcher.isAllowed(URL(string: refused)), refused)
        }
    }

    /// One Wikimedia spacer for the whole app: two clients (and the run and
    /// the Commons source, which take the same default) never send two
    /// Wikimedia requests within a second of each other.
    func testWikimediaRequestsAreSpacedAcrossClients() async throws {
        let fetcher = FakePictureFetcher()
        let gate = MusicBrainzGate(interval: .zero)
        _ = try await ArtistInfoClient(fetcher: fetcher, gate: gate).bio(wikidataID: "Q1", preferredLanguages: ["en"])
        _ = try await ArtistInfoClient(fetcher: fetcher, gate: gate).bio(wikidataID: "Q2", preferredLanguages: ["en"])
        let times = fetcher.requestTimes
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], .milliseconds(950))
    }
}
