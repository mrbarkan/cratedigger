import XCTest
@testable import CrateDiggerCore

final class StreamSourceCodableTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let s = StreamSource(id: "s1", url: "https://youtube.com/@safeplace", title: "24/7 lofi",
                             channel: "safe place", kind: .live, hue: 18,
                             addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             viewers: "1.4K", durationSeconds: nil)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(StreamSource.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isLive)
    }
}
