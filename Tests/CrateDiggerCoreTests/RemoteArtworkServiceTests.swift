#if canImport(XCTest)
import Foundation
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

    func testServerErrorIsNotCached() async {
        respond(status: 503, data: nil)
        _ = await service.coverArtImageCount(releaseMBID: "mbid-flaky")
        respond(status: 200, data: caaJSON(imageCount: 1))
        let count = await service.coverArtImageCount(releaseMBID: "mbid-flaky")
        XCTAssertEqual(count, 1, "a 503 must not be remembered as 'no images'")
    }
}
#endif
