import XCTest
@testable import CrateDiggerCore

/// Deezer's public `search/artist` and `artist/<id>/albums` answers, as
/// literals. Review Focus 3: a 200 that carries an error, HTML or nothing.
final class DeezerArtistParserTests: XCTestCase {
    static let daftPunkXL = "https://e-cdns-images.dzcdn.net/images/artist/f2bc007e9133c946ac3c3907ddc5d2ea/1000x1000-000000-80-0-0.jpg"
    static let placeholderXL = "https://e-cdns-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg"

    static func artistJSON(id: Int, name: String, xl: String?) -> String {
        let picture = xl.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":\(id),"name":"\(name)","link":"https://www.deezer.com/artist/\(id)",\
        "picture":"https://api.deezer.com/artist/\(id)/image","picture_xl":\(picture),\
        "nb_album":37,"nb_fan":4000000,"radio":true,"type":"artist"}
        """
    }

    func testSingleArtist() throws {
        let json = "{\"data\":[\(Self.artistJSON(id: 27, name: "Daft Punk", xl: Self.daftPunkXL))],\"total\":1}"
        let artists = try DeezerArtistParser.artists(Data(json.utf8))
        XCTAssertEqual(artists, [ArtistPictureCandidate(name: "Daft Punk", source: .deezer, sourceID: "27",
                                                        imageURL: URL(string: Self.daftPunkXL)!, albumTitles: [])])
    }

    func testSeveralArtists() throws {
        let json = """
        {"data":[\(Self.artistJSON(id: 415, name: "Nirvana", xl: Self.daftPunkXL)),\
        \(Self.artistJSON(id: 9_001, name: "Nirvana (UK)", xl: Self.daftPunkXL.replacingOccurrences(of: "f2bc", with: "aaaa")))],\
        "total":2,"next":"https://api.deezer.com/search/artist?q=nirvana&index=2"}
        """
        let artists = try DeezerArtistParser.artists(Data(json.utf8))
        XCTAssertEqual(artists.map(\.name), ["Nirvana", "Nirvana (UK)"])
        XCTAssertEqual(artists.map(\.sourceID), ["415", "9001"])
        XCTAssertTrue(artists.allSatisfy { $0.source == .deezer && $0.albumTitles.isEmpty })
    }

    func testPlaceholderRejected() throws {
        let json = """
        {"data":[\(Self.artistJSON(id: 1, name: "No Face", xl: Self.placeholderXL)),\
        \(Self.artistJSON(id: 2, name: "Null Face", xl: nil)),\
        \(Self.artistJSON(id: 3, name: "Empty Face", xl: "")),\
        \(Self.artistJSON(id: 4, name: "Real Face", xl: Self.daftPunkXL))],"total":4}
        """
        XCTAssertEqual(try DeezerArtistParser.artists(Data(json.utf8)).map(\.name), ["Real Face"])
    }

    /// Review M6: a picture is taken only from Deezer's own CDN over HTTPS.
    func testPicturesOnlyFromDeezersCDN() throws {
        let json = """
        {"data":[\(Self.artistJSON(id: 1, name: "Elsewhere", xl: "https://evil.example/images/artist/abc/1000x1000.jpg")),\
        \(Self.artistJSON(id: 2, name: "Plain", xl: "http://e-cdns-images.dzcdn.net/images/artist/abc/1000x1000.jpg")),\
        \(Self.artistJSON(id: 3, name: "Address", xl: "https://10.0.0.1/images/artist/abc/1000x1000.jpg")),\
        \(Self.artistJSON(id: 4, name: "Lookalike", xl: "https://dzcdn.net.evil.example/images/artist/abc/x.jpg")),\
        \(Self.artistJSON(id: 5, name: "Real", xl: Self.daftPunkXL))],"total":5}
        """
        XCTAssertEqual(try DeezerArtistParser.artists(Data(json.utf8)).map(\.name), ["Real"])
    }

    func testEmptyResult() throws {
        XCTAssertEqual(try DeezerArtistParser.artists(Data("{\"data\":[],\"total\":0}".utf8)), [])
        XCTAssertEqual(try DeezerArtistParser.albumTitles(Data("{\"data\":[],\"total\":0}".utf8)), [])
    }

    func testQuotaErrorBody() {
        let body = Data("{\"error\":{\"type\":\"Exception\",\"message\":\"Quota limit exceeded\",\"code\":4}}".utf8)
        XCTAssertThrowsError(try DeezerArtistParser.artists(body)) {
            XCTAssertEqual($0 as? ArtistPictureSourceError, .quota)
        }
        XCTAssertThrowsError(try DeezerArtistParser.albumTitles(body)) {
            XCTAssertEqual($0 as? ArtistPictureSourceError, .quota)
        }
        let other = Data("{\"error\":{\"type\":\"DataException\",\"message\":\"no data\",\"code\":800}}".utf8)
        XCTAssertThrowsError(try DeezerArtistParser.artists(other)) {
            XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed)
        }
    }

    func testHTMLBodyThrowsParseError() {
        for body in ["<html><body>502 Bad Gateway</body></html>", "", "[]", "{\"total\":3}", "{\"data\":{}}"] {
            XCTAssertThrowsError(try DeezerArtistParser.artists(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed, body)
            }
            XCTAssertThrowsError(try DeezerArtistParser.albumTitles(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? ArtistPictureSourceError, .malformed, body)
            }
        }
    }

    func testAlbumTitles() throws {
        let json = """
        {"data":[{"id":302127,"title":"Discovery","record_type":"album"},\
        {"id":6575789,"title":"Random Access Memories","record_type":"album"},\
        {"id":1,"title":"  ","record_type":"single"},{"id":2}],"total":4}
        """
        XCTAssertEqual(try DeezerArtistParser.albumTitles(Data(json.utf8)), ["Discovery", "Random Access Memories"])
    }

    func testSearchURLQuotesAndEncodesTheName() throws {
        for name in ["AC/DC", "Björk", "Simon & Garfunkel", "Earth, Wind & Fire", "Guns N' Roses", "50% Off + More"] {
            let url = DeezerArtistParser.searchURL(name: name)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "api.deezer.com")
            XCTAssertEqual(url.path, "/search/artist")
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "q" }?.value, "artist:\"\(name)\"", name)
            XCTAssertEqual(items.first { $0.name == "limit" }?.value, "10")
            XCTAssertEqual(items.count, 2, "the name must not split the query: \(url.absoluteString)")
            XCTAssertTrue(url.absoluteString.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "\"" },
                          url.absoluteString)
        }
        // A quote in the name would end Deezer's quoted term early.
        let quoted = DeezerArtistParser.searchURL(name: "The \"Quoted\" Band")
        let value = URLComponents(url: quoted, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        XCTAssertEqual(value, "artist:\"The Quoted Band\"")
    }

    func testAlbumsURL() {
        XCTAssertEqual(DeezerArtistParser.albumsURL(artistID: "27").absoluteString,
                       "https://api.deezer.com/artist/27/albums?limit=100")
        XCTAssertEqual(DeezerArtistParser.albumsURL(artistID: "../x").absoluteString,
                       "https://api.deezer.com/artist/..%2Fx/albums?limit=100",
                       "an odd id stays one path component")
    }
}
