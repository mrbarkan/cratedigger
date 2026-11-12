import XCTest
@testable import CrateDiggerCore

/// MusicBrainz artist search and lookup, Wikidata sitelinks and the Wikipedia
/// REST summary, read from JSON literals shaped like the services' answers.
final class ArtistInfoParsersTests: XCTestCase {
    static let massiveID = "10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8"

    /// `/ws/2/artist/<id>?inc=url-rels+artist-rels+genres+release-groups&fmt=json`.
    static let massiveDetail = """
    {"id":"10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8","name":"Massive Attack","sort-name":"Massive Attack",\
    "type":"Group","type-id":"e431f5f6-b5d2-343d-8b36-72607fffb74b","country":"GB","disambiguation":"",\
    "area":{"id":"8a754a16-0027-3a29-b6d7-2b40ea0481ed","name":"United Kingdom","sort-name":"United Kingdom",\
    "disambiguation":"","iso-3166-1-codes":["GB"]},\
    "begin-area":{"id":"a9ee7fdd-b8b4-4b09-b27e-1b5ae9d5f73d","name":"Bristol","sort-name":"Bristol","disambiguation":""},\
    "end-area":null,"life-span":{"begin":"1988","end":null,"ended":false},"gender":null,"isnis":[],"ipis":[],\
    "genres":[{"id":"g1","name":"electronic","count":4,"disambiguation":""},\
    {"id":"g2","name":"trip hop","count":15,"disambiguation":""},\
    {"id":"g3","name":"downtempo","count":6,"disambiguation":""},\
    {"id":"g4","name":"alternative dance","count":1,"disambiguation":""},\
    {"id":"g5","name":"dub","count":3,"disambiguation":""},\
    {"id":"g6","name":"hip hop","count":2,"disambiguation":""}],\
    "relations":[\
    {"type":"member of band","type-id":"5be4c609-9afa-4ea0-910b-12ffb71e3821","direction":"backward","target-type":"artist",\
    "begin":"1988","end":"2001","ended":true,"attributes":["original"],"attribute-values":{},\
    "artist":{"id":"m1","name":"Andrew Vowles","sort-name":"Vowles, Andrew","type":"Person","disambiguation":"Mushroom"}},\
    {"type":"member of band","type-id":"5be4c609-9afa-4ea0-910b-12ffb71e3821","direction":"backward","target-type":"artist",\
    "begin":"1988","end":null,"ended":false,"attributes":["original"],"attribute-values":{},\
    "artist":{"id":"m2","name":"Robert Del Naja","sort-name":"Del Naja, Robert","type":"Person","disambiguation":"3D"}},\
    {"type":"member of band","type-id":"5be4c609-9afa-4ea0-910b-12ffb71e3821","direction":"forward","target-type":"artist",\
    "begin":null,"end":null,"ended":false,"attributes":[],"attribute-values":{},\
    "artist":{"id":"x1","name":"Some Supergroup","sort-name":"Some Supergroup","type":"Group","disambiguation":""}},\
    {"type":"collaboration","type-id":"75c09861-6857-4ec0-9729-84eefde7fc86","direction":"backward","target-type":"artist",\
    "begin":null,"end":null,"ended":false,"attributes":[],"attribute-values":{},\
    "artist":{"id":"x2","name":"Guest Singer","sort-name":"Singer, Guest","type":"Person","disambiguation":""}},\
    {"type":"member of band","type-id":"5be4c609-9afa-4ea0-910b-12ffb71e3821","direction":"backward","target-type":"artist",\
    "begin":"1988","end":null,"ended":false,"attributes":["original"],"attribute-values":{},\
    "artist":{"id":"m3","name":"Grant Marshall","sort-name":"Marshall, Grant","type":"Person","disambiguation":"Daddy G"}},\
    {"type":"wikidata","type-id":"689870a4-a1e4-4912-b17f-7b2664215698","direction":"forward","target-type":"url",\
    "begin":null,"end":null,"ended":false,"attributes":[],"attribute-values":{},\
    "url":{"id":"u1","resource":"https://www.wikidata.org/wiki/Q11895"}},\
    {"type":"official homepage","type-id":"fe33d22f-c3b0-4d68-bd53-a856badf2b15","direction":"forward","target-type":"url",\
    "begin":null,"end":null,"ended":false,"attributes":[],"attribute-values":{},\
    "url":{"id":"u2","resource":"https://www.massiveattack.co.uk/"}}],\
    "release-groups":[\
    {"id":"rg1","title":"Blue Lines","primary-type":"Album","secondary-types":[],"first-release-date":"1991-04-08","disambiguation":""},\
    {"id":"rg2","title":"Mezzanine","primary-type":"Album","secondary-types":[],"first-release-date":"1998-04-20","disambiguation":""}]}
    """

    static let bjorkDetail = """
    {"id":"87c5dedd-371d-4a53-9f7f-80522fb7f3cb","name":"Björk","sort-name":"Björk","type":"Person",\
    "country":"IS","disambiguation":"","area":{"id":"a1","name":"Iceland","sort-name":"Iceland"},\
    "begin-area":{"id":"a2","name":"Reykjavík","sort-name":"Reykjavík"},"end-area":null,\
    "life-span":{"begin":"1965-11-21","end":null,"ended":false},"genres":[],"relations":[],"release-groups":[]}
    """

    // MARK: MusicBrainz

    func testDetailParsesKindOriginYearsMembersGenresLinks() throws {
        let detail = try ArtistInfoParsers.artistDetail(Data(Self.massiveDetail.utf8))
        let facts = detail.facts
        XCTAssertEqual(facts.kind, "Group")
        XCTAssertEqual(facts.origin, "Bristol, United Kingdom")
        XCTAssertEqual(facts.begin, "1988")
        XCTAssertNil(facts.end)
        XCTAssertNil(facts.bio)
        // Only backward "member of band" relations, current members first.
        XCTAssertEqual(facts.members, [
            ArtistMember(name: "Grant Marshall", begin: "1988", isCurrent: true),
            ArtistMember(name: "Robert Del Naja", begin: "1988", isCurrent: true),
            ArtistMember(name: "Andrew Vowles", begin: "1988", end: "2001", isCurrent: false),
        ])
        XCTAssertEqual(facts.links, [ArtistLink(kind: .musicBrainz,
                                                url: URL(string: "https://musicbrainz.org/artist/\(Self.massiveID)")!)])
        XCTAssertEqual(detail.wikidataID, "Q11895")
        XCTAssertEqual(detail.releaseGroupTitles, ["Blue Lines", "Mezzanine"])
    }

    func testPersonWithoutEndReadsToNow() throws {
        let facts = try ArtistInfoParsers.artistDetail(Data(Self.bjorkDetail.utf8)).facts
        XCTAssertEqual(facts.kind, "Person")
        XCTAssertEqual(facts.origin, "Reykjavík, Iceland")
        XCTAssertEqual(facts.begin, "1965")
        XCTAssertNil(facts.end)
        XCTAssertNil(facts.members)
        XCTAssertNil(facts.genres)
    }

    func testGenresTopFive() throws {
        let facts = try ArtistInfoParsers.artistDetail(Data(Self.massiveDetail.utf8)).facts
        XCTAssertEqual(facts.genres, ["trip hop", "downtempo", "electronic", "dub", "hip hop"])
    }

    func testEndedArtistKeepsItsYearsAndSameOriginOnce() throws {
        let json = """
        {"id":"x","name":"Talk Talk","type":"Group","area":{"name":"London"},"begin-area":{"name":"London"},\
        "life-span":{"begin":"1981","end":"1991-09","ended":true}}
        """
        let facts = try ArtistInfoParsers.artistDetail(Data(json.utf8)).facts
        XCTAssertEqual(facts.begin, "1981")
        XCTAssertEqual(facts.end, "1991")
        XCTAssertEqual(facts.origin, "London")
    }

    func testSearchCandidates() throws {
        let json = """
        {"created":"2026-11-12T00:00:00.000Z","count":2,"offset":0,"artists":[\
        {"id":"b1","type":"Group","score":100,"name":"Air","sort-name":"Air","country":"FR",\
        "area":{"id":"a","type":"Country","name":"France","sort-name":"France"},\
        "begin-area":{"id":"b","type":"City","name":"Versailles","sort-name":"Versailles"},\
        "disambiguation":"French band","life-span":{"begin":"1995","ended":null}},\
        {"id":"b2","type":"Group","score":100,"name":"Air","sort-name":"Air","disambiguation":"Japanese rock band",\
        "area":{"id":"c","type":"Country","name":"Japan","sort-name":"Japan"},"life-span":{"ended":null}},\
        {"id":"","name":"Broken"},{"name":"No id"}]}
        """
        let candidates = try ArtistInfoParsers.searchCandidates(Data(json.utf8))
        XCTAssertEqual(candidates, [
            ArtistIdentityCandidate(musicBrainzID: "b1", name: "Air", disambiguation: "French band",
                                    origin: "Versailles, France"),
            ArtistIdentityCandidate(musicBrainzID: "b2", name: "Air", disambiguation: "Japanese rock band",
                                    origin: "Japan"),
        ])
    }

    func testMalformedMusicBrainzThrowsMalformed() {
        for body in ["<html>busy</html>", "", "[]"] {
            XCTAssertThrowsError(try ArtistInfoParsers.searchCandidates(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
            XCTAssertThrowsError(try ArtistInfoParsers.artistDetail(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
            }
        }
    }

    // MARK: Wikidata and Wikipedia

    static func entityJSON(id: String, sitelinks: [String: String]) -> String {
        let links = sitelinks.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":{\"site\":\"\($0.key)\",\"title\":\"\($0.value)\",\"badges\":[]}" }
        return "{\"entities\":{\"\(id)\":{\"type\":\"item\",\"id\":\"\(id)\",\"sitelinks\":{\(links.joined(separator: ","))},\"claims\":{}}}}"
    }

    func testSitelinksAndLanguageChoice() throws {
        let entity = Self.entityJSON(id: "Q11895", sitelinks: [
            "enwiki": "Massive Attack", "ptwiki": "Massive Attack (banda)", "commonswiki": "Category:Massive Attack",
        ])
        let titles = try ArtistInfoParsers.wikipediaTitles(fromEntity: Data(entity.utf8), id: "Q11895")
        XCTAssertEqual(titles["enwiki"], "Massive Attack")
        XCTAssertEqual(titles["ptwiki"], "Massive Attack (banda)")

        let pt = ArtistInfoParsers.wikipediaChoice(sitelinks: titles, preferredLanguages: ["pt", "en"])
        XCTAssertEqual(pt?.language, "pt")
        XCTAssertEqual(pt?.title, "Massive Attack (banda)")

        // A region suffix is ignored: pt-BR reads as pt.
        XCTAssertEqual(ArtistInfoParsers.wikipediaChoice(sitelinks: titles, preferredLanguages: ["pt-BR"])?.language, "pt")

        let english = ArtistInfoParsers.wikipediaChoice(sitelinks: ["enwiki": "Massive Attack"],
                                                        preferredLanguages: ["pt", "en"])
        XCTAssertEqual(english?.language, "en")
        XCTAssertEqual(english?.title, "Massive Attack")
        // Not in the preferred list, English is still the fallback.
        XCTAssertEqual(ArtistInfoParsers.wikipediaChoice(sitelinks: ["enwiki": "Air"], preferredLanguages: ["ja"])?.language, "en")

        XCTAssertNil(ArtistInfoParsers.wikipediaChoice(sitelinks: ["commonswiki": "Category:X"], preferredLanguages: ["pt", "en"]))
        XCTAssertNil(ArtistInfoParsers.wikipediaChoice(sitelinks: [:], preferredLanguages: ["pt", "en"]))
    }

    func testMergedEntityIsReadUnderItsNewID() throws {
        let entity = Self.entityJSON(id: "Q2", sitelinks: ["enwiki": "Air (French band)"])
        XCTAssertEqual(try ArtistInfoParsers.wikipediaTitles(fromEntity: Data(entity.utf8), id: "Q1"),
                       ["enwiki": "Air (French band)"])
        XCTAssertThrowsError(try ArtistInfoParsers.wikipediaTitles(fromEntity: Data("[]".utf8), id: "Q1"))
    }

    static let summaryJSON = """
    {"type":"standard","title":"Massive Attack","displaytitle":"<span class=\\"mw-page-title-main\\">Massive Attack</span>",\
    "namespace":{"id":0,"text":""},"wikibase_item":"Q11895","pageid":171366,"lang":"en","dir":"ltr",\
    "description":"English trip hop group","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Massive_Attack",\
    "revisions":"https://en.wikipedia.org/wiki/Massive_Attack?action=history"},\
    "mobile":{"page":"https://en.m.wikipedia.org/wiki/Massive_Attack"}},\
    "extract":"Massive Attack are an English trip hop group formed in 1988 in Bristol.\\nThe group's debut album Blue Lines was released in 1991.",\
    "extract_html":"<p><b>Massive Attack</b> are an English trip hop group.</p>"}
    """

    func testSummaryLeadParagraph() throws {
        let summary = try XCTUnwrap(ArtistInfoParsers.summary(Data(Self.summaryJSON.utf8)))
        XCTAssertEqual(summary.extract, "Massive Attack are an English trip hop group formed in 1988 in Bristol.")
        XCTAssertEqual(summary.pageURL, URL(string: "https://en.wikipedia.org/wiki/Massive_Attack"))
    }

    func testMissingSummaryIsNil() throws {
        let notFound = """
        {"type":"https://mediawiki.org/wiki/HyperSwitch/errors/not_found","title":"Not found.","method":"get",\
        "detail":"Page or revision not found.","uri":"/en.wikipedia.org/v1/page/summary/Nobody"}
        """
        XCTAssertNil(try ArtistInfoParsers.summary(Data(notFound.utf8)))
        let disambiguation = """
        {"type":"disambiguation","title":"Air","extract":"Air may refer to:",\
        "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Air"}}}
        """
        XCTAssertNil(try ArtistInfoParsers.summary(Data(disambiguation.utf8)))
        let empty = """
        {"type":"standard","title":"X","extract":"  \\n ","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/X"}}}
        """
        XCTAssertNil(try ArtistInfoParsers.summary(Data(empty.utf8)))
        // No link to credit means no text: the attribution must link the article.
        let offSite = """
        {"type":"standard","title":"X","extract":"Text.","content_urls":{"desktop":{"page":"https://evil.example/wiki/X"}}}
        """
        XCTAssertNil(try ArtistInfoParsers.summary(Data(offSite.utf8)))
        XCTAssertThrowsError(try ArtistInfoParsers.summary(Data("<html>".utf8)))
    }
}
