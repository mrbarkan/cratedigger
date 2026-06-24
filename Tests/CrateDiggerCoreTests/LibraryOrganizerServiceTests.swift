#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LibraryOrganizerServiceTests: XCTestCase {
    func testOrganizeMove() async throws {
        try await withTemporaryDirectory(prefix: "OrganizerMoveTest") { tempDir in
            let sourceDir = tempDir.appendingPathComponent("Original")
            let destDir = tempDir.appendingPathComponent("Organized")
            
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let trackURL = sourceDir.appendingPathComponent("original_file.flac")
            try "music data".write(to: trackURL, atomically: true, encoding: .utf8)
            
            let track = AudioTrack(
                fileURL: trackURL,
                title: "Telegraph Lines",
                artist: "Boards of Canada",
                album: "The Campfire Headphase",
                year: 2005,
                trackNumber: 3
            )
            let loadedTrack = LoadedTrack(track: track, metadata: ConversionMetadata(
                title: "Telegraph Lines",
                artist: "Boards of Canada",
                albumArtist: "Boards of Canada",
                album: "The Campfire Headphase",
                trackNumber: 3,
                year: 2005
            ))
            
            let organizer = LibraryOrganizerService(fileManager: .default)
            
            try await organizer.organize(
                tracks: [loadedTrack],
                destinationFolder: destDir,
                copyOnly: false
            )
            
            // Expected target layout:
            // Organized/Boards of Canada/[2005] - The Campfire Headphase/03 - Telegraph Lines.flac
            let expectedURL = destDir
                .appendingPathComponent("Boards of Canada")
                .appendingPathComponent("[2005] - The Campfire Headphase")
                .appendingPathComponent("03 - Telegraph Lines.flac")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: trackURL.path)) // Move: original should be deleted
        }
    }
    
    func testOrganizePreservesRecordMarkers() async throws {
        try await withTemporaryDirectory(prefix: "OrganizerMarkersTest") { tempDir in
            let sourceDir = tempDir.appendingPathComponent("Original")
            let destDir = tempDir.appendingPathComponent("Organized")
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let trackURL = sourceDir.appendingPathComponent("sideA.aiff")
            try "music data".write(to: trackURL, atomically: true, encoding: .utf8)

            let loaded = LoadedTrack(
                track: AudioTrack(fileURL: trackURL, title: "Side A", artist: "Lorde", album: "Solar Power"),
                metadata: ConversionMetadata(albumArtist: "Lorde", album: "Solar Power"),
                recordMarkers: [
                    RecordMarker(startSeconds: 0, endSeconds: 180, title: "Track 01"),
                    RecordMarker(startSeconds: 180, endSeconds: 400, title: "Track 02")
                ]
            )

            let organizer = LibraryOrganizerService(fileManager: .default)
            let result = try await organizer.organize(tracks: [loaded], destinationFolder: destDir, copyOnly: true)

            // Markers survive the move/copy (they're time-based, not path-based).
            XCTAssertEqual(result.first?.recordMarkers?.count, 2)
            XCTAssertEqual(result.first?.recordMarkers?[1].title, "Track 02")
            XCTAssertNotEqual(result.first?.track.fileURL, trackURL, "file should be relocated")
        }
    }

    func testOrganizeCopyAndCollision() async throws {
        try await withTemporaryDirectory(prefix: "OrganizerCopyTest") { tempDir in
            let sourceDir = tempDir.appendingPathComponent("Original")
            let destDir = tempDir.appendingPathComponent("Organized")
            
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let trackURL = sourceDir.appendingPathComponent("original_file.mp3")
            try "mp3 data".write(to: trackURL, atomically: true, encoding: .utf8)
            
            let track = AudioTrack(
                fileURL: trackURL,
                title: "Song",
                artist: "Artist",
                album: "Album",
                year: 2020,
                trackNumber: 1
            )
            let loadedTrack = LoadedTrack(track: track, metadata: ConversionMetadata(
                title: "Song",
                artist: "Artist",
                albumArtist: "Artist",
                album: "Album",
                trackNumber: 1,
                year: 2020
            ))
            
            let organizer = LibraryOrganizerService(fileManager: .default)
            
            // First run: Copy
            try await organizer.organize(
                tracks: [loadedTrack],
                destinationFolder: destDir,
                copyOnly: true
            )
            
            let targetURL = destDir
                .appendingPathComponent("Artist")
                .appendingPathComponent("[2020] - Album")
                .appendingPathComponent("01 - Song.mp3")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: trackURL.path)) // Copy: original remains
            
            // Second run: Copy again (should trigger collision resolution)
            try await organizer.organize(
                tracks: [loadedTrack],
                destinationFolder: destDir,
                copyOnly: true
            )
            
            let collisionURL = destDir
                .appendingPathComponent("Artist")
                .appendingPathComponent("[2020] - Album")
                .appendingPathComponent("01 - Song (1).mp3")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: collisionURL.path))
        }
    }
    
    func testOrganizeWithoutAlbumArtist() async throws {
        try await withTemporaryDirectory(prefix: "OrganizerNoArtistTest") { tempDir in
            let sourceDir = tempDir.appendingPathComponent("Original")
            let destDir = tempDir.appendingPathComponent("Organized")
            
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let nestedDir = sourceDir.appendingPathComponent("FolderA").appendingPathComponent("FolderB")
            try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
            
            let track1URL = nestedDir.appendingPathComponent("track1.mp3")
            let track2URL = nestedDir.appendingPathComponent("track2.mp3")
            try "track 1 data".write(to: track1URL, atomically: true, encoding: .utf8)
            try "track 2 data".write(to: track2URL, atomically: true, encoding: .utf8)
            
            let track1 = AudioTrack(fileURL: track1URL, title: "Track 1")
            let track2 = AudioTrack(fileURL: track2URL, title: "Track 2")
            let loaded1 = LoadedTrack(track: track1, metadata: ConversionMetadata(title: "Track 1"))
            let loaded2 = LoadedTrack(track: track2, metadata: ConversionMetadata(title: "Track 2"))
            
            let organizer = LibraryOrganizerService(fileManager: .default)
            
            let result = try await organizer.organize(
                tracks: [loaded1, loaded2],
                destinationFolder: destDir,
                copyOnly: true,
                organiseByAlbumArtist: false
            )
            
            let expected1 = destDir.appendingPathComponent("track1.mp3")
            let expected2 = destDir.appendingPathComponent("track2.mp3")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected1.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected2.path))
            
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].track.fileURL.path, expected1.path)
            XCTAssertEqual(result[1].track.fileURL.path, expected2.path)
        }
    }
    
    func testOrganizeWithoutAlbumArtistHierarchical() async throws {
        try await withTemporaryDirectory(prefix: "OrganizerNoArtistHierarchicalTest") { tempDir in
            let sourceDir = tempDir.appendingPathComponent("Original")
            let destDir = tempDir.appendingPathComponent("Organized")
            
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let dirA = sourceDir.appendingPathComponent("FolderA")
            let dirB = sourceDir.appendingPathComponent("FolderB")
            try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
            
            let track1URL = dirA.appendingPathComponent("track1.mp3")
            let track2URL = dirB.appendingPathComponent("track2.mp3")
            try "track 1".write(to: track1URL, atomically: true, encoding: .utf8)
            try "track 2".write(to: track2URL, atomically: true, encoding: .utf8)
            
            let track1 = AudioTrack(fileURL: track1URL, title: "Track 1")
            let track2 = AudioTrack(fileURL: track2URL, title: "Track 2")
            let loaded1 = LoadedTrack(track: track1, metadata: ConversionMetadata(title: "Track 1"))
            let loaded2 = LoadedTrack(track: track2, metadata: ConversionMetadata(title: "Track 2"))
            
            let organizer = LibraryOrganizerService(fileManager: .default)
            
            let result = try await organizer.organize(
                tracks: [loaded1, loaded2],
                destinationFolder: destDir,
                copyOnly: true,
                organiseByAlbumArtist: false
            )
            
            let expected1 = destDir.appendingPathComponent("FolderA").appendingPathComponent("track1.mp3")
            let expected2 = destDir.appendingPathComponent("FolderB").appendingPathComponent("track2.mp3")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected1.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected2.path))
            
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].track.fileURL.path, expected1.path)
            XCTAssertEqual(result[1].track.fileURL.path, expected2.path)
        }
    }
}
#endif
