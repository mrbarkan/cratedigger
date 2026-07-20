#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LibraryCleanupServiceTests: XCTestCase {
    func testFindDeadTracks() throws {
        try withTemporaryDirectory(prefix: "CleanupDeadTracks") { tempDir in
            let existingURL = tempDir.appendingPathComponent("exists.mp3")
            let deadURL = tempDir.appendingPathComponent("dead.mp3")
            
            try "stub".write(to: existingURL, atomically: true, encoding: .utf8)
            
            let track1 = AudioTrack(fileURL: existingURL, title: "Track 1", artist: "Artist", album: "Album")
            let track2 = AudioTrack(fileURL: deadURL, title: "Track 2", artist: "Artist", album: "Album")
            
            let loaded1 = LoadedTrack(track: track1, metadata: ConversionMetadata())
            let loaded2 = LoadedTrack(track: track2, metadata: ConversionMetadata())
            
            let index = LibraryIndex.build(from: [loaded1, loaded2])
            
            let cleanupService = LibraryCleanupService(fileManager: .default)
            let deadTracks = cleanupService.findDeadTracks(in: index)
            
            XCTAssertEqual(deadTracks.count, 1)
            XCTAssertEqual(deadTracks.first?.track.id, track2.id)
        }
    }
    
    func testFindDuplicatesPriority() throws {
        try withTemporaryDirectory(prefix: "CleanupDuplicates") { tempDir in
            let urlFLAC = tempDir.appendingPathComponent("song_lossless.flac")
            let urlMP3High = tempDir.appendingPathComponent("song_high.mp3")
            let urlMP3Low = tempDir.appendingPathComponent("song_low.mp3")
            
            // Create dummy files with different sizes so size fallback is tested too
            try "lossless large file".write(to: urlFLAC, atomically: true, encoding: .utf8)
            try "high bitrate medium".write(to: urlMP3High, atomically: true, encoding: .utf8)
            try "low".write(to: urlMP3Low, atomically: true, encoding: .utf8)
            
            // 1. FLAC (Lossless)
            let trackFLAC = AudioTrack(
                fileURL: urlFLAC, title: "Adventure", artist: "Daft Punk", album: "Discovery",
                formatName: "flac", bitrateKbps: 900, sampleRateHz: 44100
            )
            
            // 2. MP3 320kbps
            let trackMP3High = AudioTrack(
                fileURL: urlMP3High, title: "Adventure", artist: "Daft Punk", album: "Discovery",
                formatName: "mp3", bitrateKbps: 320, sampleRateHz: 44100
            )
            
            // 3. MP3 128kbps
            let trackMP3Low = AudioTrack(
                fileURL: urlMP3Low, title: "Adventure", artist: "Daft Punk", album: "Discovery",
                formatName: "mp3", bitrateKbps: 128, sampleRateHz: 44100
            )
            
            let loadedFLAC = LoadedTrack(track: trackFLAC, metadata: ConversionMetadata())
            let loadedMP3High = LoadedTrack(track: trackMP3High, metadata: ConversionMetadata())
            let loadedMP3Low = LoadedTrack(track: trackMP3Low, metadata: ConversionMetadata())
            
            let index = LibraryIndex.build(from: [loadedFLAC, loadedMP3High, loadedMP3Low])
            
            let cleanupService = LibraryCleanupService(fileManager: .default)
            let duplicates = cleanupService.findDuplicates(in: index)
            
            XCTAssertEqual(duplicates.count, 1)
            let group = duplicates[0]
            
            // Lossless (FLAC) should be the best version
            XCTAssertEqual(group.bestTrack.track.id, trackFLAC.id)
            
            // MP3s should be designated as worst tracks
            XCTAssertEqual(group.worstTracks.count, 2)
            XCTAssertEqual(group.worstTracks[0].track.id, trackMP3High.id) // 320 is better than 128
            XCTAssertEqual(group.worstTracks[1].track.id, trackMP3Low.id)
        }
    }
    
    private func grouped() throws -> (LibraryIndex, [LoadedTrack]) {
        // Two pressings of Discovery, each with "One More Time".
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mk(_ album: String, _ fmt: String) throws -> LoadedTrack {
            let url = dir.appendingPathComponent("\(album)-\(fmt).\(fmt)")
            try "x".write(to: url, atomically: true, encoding: .utf8)
            let t = AudioTrack(fileURL: url, title: "One More Time", artist: "Daft Punk",
                               album: album, formatName: fmt, bitrateKbps: 900, sampleRateHz: 44100)
            return LoadedTrack(track: t, metadata: ConversionMetadata())
        }
        let us = try mk("Discovery", "flac")
        let jp = try mk("Discovery (JP)", "alac")
        let planner = OutputPathPlanner()
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: planner.albumFolderKey(for: us),
                               members: [VersionMember(key: planner.albumFolderKey(for: us)),
                                         VersionMember(key: planner.albumFolderKey(for: jp))])
        return (LibraryIndex.build(from: [us, jp], groups: [group]), [us, jp])
    }

    func testGroupedVersionsNotFlaggedAsDuplicates() throws {
        let (index, _) = try grouped()
        let dupes = LibraryCleanupService(fileManager: .default).findDuplicates(in: index)
        XCTAssertEqual(dupes.count, 0)
    }

    func testDuplicateWithinSinglePressingStillFlagged() throws {
        // Same pressing ("Discovery") contains "One More Time" twice.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mk(_ album: String, _ file: String) throws -> LoadedTrack {
            let url = dir.appendingPathComponent(file)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            let t = AudioTrack(fileURL: url, title: "One More Time", artist: "Daft Punk",
                               album: album, formatName: "flac", bitrateKbps: 900, sampleRateHz: 44100)
            return LoadedTrack(track: t, metadata: ConversionMetadata())
        }
        let a = try mk("Discovery", "a.flac")
        let b = try mk("Discovery", "b.flac")          // duplicate inside the same pressing
        let jp = try mk("Discovery (JP)", "jp.flac")
        let planner = OutputPathPlanner()
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: planner.albumFolderKey(for: a),
                               members: [VersionMember(key: planner.albumFolderKey(for: a)),
                                         VersionMember(key: planner.albumFolderKey(for: jp))])
        let index = LibraryIndex.build(from: [a, b, jp], groups: [group])
        let dupes = LibraryCleanupService(fileManager: .default).findDuplicates(in: index)
        XCTAssertEqual(dupes.count, 1)
    }

    func testDeleteAndCopyTracks() throws {
        try withTemporaryDirectory(prefix: "CleanupDeleteCopy") { tempDir in
            let file1 = tempDir.appendingPathComponent("track1.mp3")
            let file2 = tempDir.appendingPathComponent("track2.mp3")

            try "song1".write(to: file1, atomically: true, encoding: .utf8)
            try "song2".write(to: file2, atomically: true, encoding: .utf8)

            let track1 = LoadedTrack(track: AudioTrack(fileURL: file1, title: "Track 1"), metadata: ConversionMetadata())
            let track2 = LoadedTrack(track: AudioTrack(fileURL: file2, title: "Track 2"), metadata: ConversionMetadata())

            let cleanupService = LibraryCleanupService(fileManager: .default)

            // Copy to a new folder
            let destFolder = tempDir.appendingPathComponent("CopiedFolder")
            try cleanupService.copyTracks([track1, track2], to: destFolder)

            XCTAssertTrue(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("track1.mp3").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("track2.mp3").path))

            // Delete track1 (non-trash, simple delete for test speed and reliability)
            try cleanupService.deleteTracks([track1], useTrash: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
        }
    }

    func testNormalizeForMatchStripsDecorationAndPunctuation() {
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("One More Time (Remastered 2011)"),
            "one more time"
        )
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("Harder, Better, Faster, Stronger [Explicit]"),
            "harder better faster stronger"
        )
        // Different-recording markers are NOT stripped.
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("Around the World (Live)"),
            "around the world live"
        )
    }

    func testNormalizeForMatchUnifiesFeaturing() {
        let a = LibraryCleanupService.normalizeForMatch("Stardust feat. Ben Diamond")
        let b = LibraryCleanupService.normalizeForMatch("Stardust ft. Ben Diamond")
        let c = LibraryCleanupService.normalizeForMatch("Stardust featuring Ben Diamond")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    func testDuplicateMatchKeyNilForEmptyTitle() {
        XCTAssertNil(LibraryCleanupService.duplicateMatchKey(artist: "Daft Punk", title: "  "))
        XCTAssertNotNil(LibraryCleanupService.duplicateMatchKey(artist: "", title: "Aerodynamic"))
    }
}
#endif
