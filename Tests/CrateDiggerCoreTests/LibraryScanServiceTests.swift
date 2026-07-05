#if canImport(XCTest)
import AppKit
import XCTest
@testable import CrateDiggerCore

/// Covers the concurrent `scanFolder` path: results must be identical to the
/// old serial loop (count, sorted order, artwork resolution) and deterministic
/// across repeated scans.
final class LibraryScanServiceTests: XCTestCase {
    private final class TitleProbe: MetadataProbing {
        /// Keyed by last path component; populated before the scan and only
        /// read afterwards, so concurrent probe calls are pure dictionary reads.
        let tagsByFilename: [String: [String: String]]

        init(tagsByFilename: [String: [String: String]]) {
            self.tagsByFilename = tagsByFilename
        }

        func probe(url: URL) throws -> ProbedMetadata {
            ProbedMetadata(
                formatTags: tagsByFilename[url.lastPathComponent] ?? [:],
                streams: [ProbedStreamMetadata(index: 0, codecType: "audio", codecName: "mp3", tags: [:], dispositions: [:])]
            )
        }
    }

    func testConcurrentScanMatchesSerialResults() async throws {
        try await withTemporaryDirectory(prefix: "LibraryScanServiceTests") { tempDir in
            let fileManager = FileManager.default

            let albumA = tempDir.appendingPathComponent("AlbumA")
            let albumB = tempDir.appendingPathComponent("AlbumB")
            try fileManager.createDirectory(at: albumA, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: albumB, withIntermediateDirectories: true)

            let files: [(URL, String)] = [
                (albumA.appendingPathComponent("a1.mp3"), "Alpha"),
                (albumA.appendingPathComponent("a2.mp3"), "Beta"),
                (albumB.appendingPathComponent("b1.flac"), "Gamma"),
                (albumB.appendingPathComponent("b2.m4a"), "Delta"),
                (tempDir.appendingPathComponent("loose.mp3"), "Epsilon")
            ]
            for (url, title) in files {
                try "dummy audio: \(title)".write(to: url, atomically: true, encoding: .utf8)
            }
            // A skipped non-audio file proves filtering still works.
            try "notes".write(to: tempDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

            // Only AlbumA has a cover; its tracks must share one artwork hash.
            let coverData = try makeImageData()
            try coverData.write(to: albumA.appendingPathComponent("cover.jpg"))

            let probe = TitleProbe(tagsByFilename: Dictionary(
                uniqueKeysWithValues: files.map { ($0.0.lastPathComponent, ["title": $0.1, "artist": "Tester", "album": "Fixture"]) }
            ))
            let scanner = LibraryScanService(
                fileManager: fileManager,
                artworkService: ArtworkService(),
                remoteArtworkService: nil,
                metadataProbe: probe
            )

            let tracks = await scanner.scanFolder(tempDir)

            XCTAssertEqual(tracks.count, 5)
            XCTAssertEqual(tracks.map { $0.track.title }, ["Alpha", "Beta", "Delta", "Epsilon", "Gamma"])
            XCTAssertEqual(
                tracks.map { $0.track.fileURL.lastPathComponent }.sorted(),
                files.map { $0.0.lastPathComponent }.sorted()
            )

            // AlbumA tracks resolved the same folder cover; the rest have none.
            let albumATracks = tracks.filter { $0.track.fileURL.deletingLastPathComponent().lastPathComponent == "AlbumA" }
            XCTAssertEqual(albumATracks.count, 2)
            XCTAssertEqual(Set(albumATracks.map { $0.track.artworkHash }).count, 1)
            XCTAssertNotNil(albumATracks[0].track.artworkHash)
            XCTAssertEqual(albumATracks[0].track.artworkSource, .folderImage)
            for other in tracks where other.track.fileURL.deletingLastPathComponent().lastPathComponent != "AlbumA" {
                XCTAssertNil(other.track.artworkHash, "\(other.track.title) should have no artwork")
            }

            // Rescanning is deterministic despite concurrent completion order.
            let rescanned = await scanner.scanFolder(tempDir)
            XCTAssertEqual(
                rescanned.map { [$0.track.title, $0.track.fileURL.path, $0.track.artworkHash ?? ""] },
                tracks.map { [$0.track.title, $0.track.fileURL.path, $0.track.artworkHash ?? ""] }
            )
        }
    }
}
#endif
