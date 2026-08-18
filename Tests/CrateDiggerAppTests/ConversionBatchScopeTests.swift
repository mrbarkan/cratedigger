#if canImport(XCTest)
import XCTest
@testable import CrateDiggerApp

/// The scope enum lost "All Loaded Tracks" (and a short-lived "Nothing"), and a
/// saved selection carrying one of those raw values must not decode into
/// something that converts a whole library by surprise.
final class ConversionBatchScopeTests: XCTestCase {

    private func decode(_ raw: Int) throws -> ConversionBatchScope {
        try JSONDecoder().decode(ConversionBatchScope.self, from: Data("\(raw)".utf8))
    }

    func testRetiredRawValuesDecodeToTheEmptyScope() throws {
        for raw in [0, 1, 2, 3] {   // selectedTracks, currentAlbum, allLoadedTracks, nothing
            XCTAssertEqual(try decode(raw), .queue,
                           "raw \(raw) is retired and must not resolve to a populated scope")
        }
    }

    func testCurrentRawValuesRoundTrip() throws {
        for scope in ConversionBatchScope.allCases {
            let data = try JSONEncoder().encode(scope)
            XCTAssertEqual(try JSONDecoder().decode(ConversionBatchScope.self, from: data), scope)
        }
    }

    /// Raw values must stay put — reusing a retired one would make an old saved
    /// selection silently mean a different scope.
    func testRawValuesArePinned() {
        XCTAssertEqual(ConversionBatchScope.queue.rawValue, 10)
        XCTAssertEqual(ConversionBatchScope.prep.rawValue, 11)
        XCTAssertEqual(ConversionBatchScope.selection.rawValue, 12)
    }
}
#endif
