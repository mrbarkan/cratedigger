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

    /// Deep recursion + single files: a track nested several folders down is
    /// found, and scanning a plain file URL (Finder drop) yields that track
    /// instead of nothing — a directory enumerator over a file is empty.
    func testScanReachesNestedFoldersAndSingleFiles() async throws {
        try await withTemporaryDirectory(prefix: "LibraryScanServiceTests") { tempDir in
            let fileManager = FileManager.default

            let deep = tempDir.appendingPathComponent("a/b/c/d")
            try fileManager.createDirectory(at: deep, withIntermediateDirectories: true)
            let nested = deep.appendingPathComponent("deep.mp3")
            try "dummy audio".write(to: nested, atomically: true, encoding: .utf8)

            let probe = TitleProbe(tagsByFilename: ["deep.mp3": ["title": "Deep"]])
            let scanner = LibraryScanService(
                fileManager: fileManager,
                artworkService: ArtworkService(),
                remoteArtworkService: nil,
                metadataProbe: probe
            )

            let folderScan = await scanner.scanFolder(tempDir)
            XCTAssertEqual(folderScan.map { $0.track.title }, ["Deep"])

            let fileScan = await scanner.scanFolder(nested)
            XCTAssertEqual(fileScan.map { $0.track.title }, ["Deep"])

            // A non-audio file scans to nothing rather than crashing/misfiling.
            let stray = tempDir.appendingPathComponent("cover.txt")
            try "not audio".write(to: stray, atomically: true, encoding: .utf8)
            let strayScan = await scanner.scanFolder(stray)
            XCTAssertTrue(strayScan.isEmpty)
        }
    }
}

final class LibraryScanServiceDSDTests: XCTestCase {
    /// Fake probe that reports a DSD64 audio stream, like ffprobe does for .dsf.
    private final class DSDProbe: MetadataProbing {
        func probe(url: URL) throws -> ProbedMetadata {
            ProbedMetadata(
                formatName: "dsf",
                formatBitRateBps: nil,
                formatTags: ["title": "Test DSD", "artist": "A", "album": "B"],
                streams: [ProbedStreamMetadata(
                    index: 0, codecType: "audio", codecName: "dsd_lsbf",
                    sampleRateHz: 2_822_400, bitRateBps: nil, tags: [:], dispositions: [:])]
            )
        }
    }

    func testDSFExtensionIsSupported() {
        XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.contains("dsf"))
        XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.contains("dff"))
    }

    func testScannedDSFGetsDSDLabel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsdscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty stand-in file; the fake probe supplies the metadata.
        try Data().write(to: dir.appendingPathComponent("01 Track.dsf"))

        let scanner = LibraryScanService(metadataProbe: DSDProbe())
        let tracks = await scanner.scanFolder(dir)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.track.formatName, "DSD64")
    }
}
#endif
