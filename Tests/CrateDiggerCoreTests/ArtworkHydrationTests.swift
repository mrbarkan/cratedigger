#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ArtworkHydrationTests: XCTestCase {
    private func asset(hash: String, data: Data) -> ArtworkAsset {
        ArtworkAsset(
            source: .embedded,
            hash: hash,
            dimensions: ArtworkDimensions(width: 10, height: 10),
            data: data
        )
    }

    func testHydratedRefillsEmptyDataFromCacheByHash() {
        // Mirrors the .cdlib round-trip: the asset keeps its hash but loses its
        // bytes; hydration must find them again by hash.
        let service = ArtworkService()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        service.ingest(asset(hash: "cover-hash", data: bytes))

        let stripped = asset(hash: "cover-hash", data: Data())
        XCTAssertEqual(service.hydrated(stripped).data, bytes)
    }

    func testHydratedLeavesPresentDataUntouched() {
        let service = ArtworkService()
        let present = asset(hash: "h", data: Data([1, 2, 3]))
        XCTAssertEqual(service.hydrated(present).data, Data([1, 2, 3]))
    }

    func testHydratedReturnsEmptyWhenHashUnknown() {
        let service = ArtworkService()
        let unknown = asset(hash: "not-cached", data: Data())
        XCTAssertTrue(service.hydrated(unknown).data.isEmpty)
    }
}
#endif
