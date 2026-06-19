#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LastFMScrobblerTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
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

    private var scrobbler: LastFMScrobbler!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        scrobbler = LastFMScrobbler(session: session)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchSessionSuccess() async throws {
        let token = "test_token"
        let expectedUsername = "cratedigger_user"
        let expectedSessionKey = "session_key_12345"
        
        let jsonResponse = """
        {
            "session": {
                "name": "\(expectedUsername)",
                "key": "\(expectedSessionKey)",
                "subscriber": 0
            }
        }
        """
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                XCTFail("Invalid request URL")
                throw NSError(domain: "Test", code: 0)
            }
            
            // Check that method parameter is present
            let method = components.queryItems?.first(where: { $0.name == "method" })?.value
            XCTAssertEqual(method, "auth.getSession")
            
            let passedToken = components.queryItems?.first(where: { $0.name == "token" })?.value
            XCTAssertEqual(passedToken, token)
            
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, jsonResponse.data(using: .utf8))
        }
        
        let result = try await scrobbler.fetchSession(token: token)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.username, expectedUsername)
        XCTAssertEqual(result?.sessionKey, expectedSessionKey)
    }
    
    func testUpdateNowPlaying() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                XCTFail("Invalid request URL")
                throw NSError(domain: "Test", code: 0)
            }
            
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "method" })?.value, "track.updateNowPlaying")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "artist" })?.value, "Aphex Twin")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "track" })?.value, "Xtal")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "sk" })?.value, "sk123")
            
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8))
        }
        
        let success = try await scrobbler.updateNowPlaying(
            artist: "Aphex Twin",
            track: "Xtal",
            album: "Selected Ambient Works 85-92",
            sessionKey: "sk123"
        )
        XCTAssertTrue(success)
    }

    func testScrobble() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                XCTFail("Invalid request URL")
                throw NSError(domain: "Test", code: 0)
            }
            
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "method" })?.value, "track.scrobble")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "artist" })?.value, "Aphex Twin")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "track" })?.value, "Xtal")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "timestamp" })?.value, "1700000000")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "sk" })?.value, "sk123")
            
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8))
        }
        
        let success = try await scrobbler.scrobble(
            artist: "Aphex Twin",
            track: "Xtal",
            album: "Selected Ambient Works 85-92",
            timestamp: 1700000000,
            sessionKey: "sk123"
        )
        XCTAssertTrue(success)
    }
}
#endif
