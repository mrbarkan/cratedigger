#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class MetadataNormalizationTests: XCTestCase {
    func testNormalizeExtractsCanonicalTrackAndDiscTotals() {
        let tags: [String: String] = [
            "TITLE": "And It Rained All Night (Burial Remix)",
            "ARTIST": "Thom Yorke",
            "ALBUM": "The Eraser RMXS [Japan]",
            "DATE": "2008",
            "track": "1",
            "TRACKTOTAL": "9",
            "disc": "1",
            "DISCTOTAL": "1"
        ]

        let normalized = MetadataNormalization.normalize(formatTags: tags)

        XCTAssertEqual(normalized.title, "And It Rained All Night (Burial Remix)")
        XCTAssertEqual(normalized.artist, "Thom Yorke")
        XCTAssertEqual(normalized.album, "The Eraser RMXS [Japan]")
        XCTAssertEqual(normalized.year, 2008)
        XCTAssertEqual(normalized.trackNumber, 1)
        XCTAssertEqual(normalized.trackTotal, 9)
        XCTAssertEqual(normalized.discNumber, 1)
        XCTAssertEqual(normalized.discTotal, 1)
    }

    func testNormalizePreservesCustomTags() {
        let tags: [String: String] = [
            "TITLE": "Track",
            "BARCODE": "4943674082957",
            "CATALOG": "XLCD335J"
        ]

        let normalized = MetadataNormalization.normalize(formatTags: tags)

        XCTAssertTrue(
            normalized.customTagPairs.contains(MetadataTagPair(key: "BARCODE", value: "4943674082957"))
        )
        XCTAssertTrue(
            normalized.customTagPairs.contains(MetadataTagPair(key: "CATALOG", value: "XLCD335J"))
        )
    }

    func testNormalizeBackfillsFromFallbackMetadata() {
        let fallback = ConversionMetadata(
            title: "Fallback Title",
            artist: "Fallback Artist",
            trackNumber: 1,
            trackTotal: 12
        )

        let normalized = MetadataNormalization.normalize(formatTags: [:], fallback: fallback)

        XCTAssertEqual(normalized.title, "Fallback Title")
        XCTAssertEqual(normalized.artist, "Fallback Artist")
        XCTAssertEqual(normalized.trackNumber, 1)
        XCTAssertEqual(normalized.trackTotal, 12)
    }
}
#endif
