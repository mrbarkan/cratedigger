#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaylistServiceTests: XCTestCase {
    private final class MockFileManager: FileManager {
        let appSupportURL: URL
        
        init(appSupportURL: URL) {
            self.appSupportURL = appSupportURL
            super.init()
        }
        
        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            if directory == .applicationSupportDirectory {
                return [appSupportURL]
            }
            return super.urls(for: directory, in: domainMask)
        }
    }

    func testPlaylistLifecycle() throws {
        try withTemporaryDirectory(prefix: "PlaylistServiceTests") { tempDir in
            let mockFM = MockFileManager(appSupportURL: tempDir)
            let service = PlaylistService(fileManager: mockFM)
            
            // 1. Initially empty
            XCTAssertTrue(service.listPlaylists().isEmpty)
            
            // 2. Save playlist
            let playlistName = "Synthwave Classics"
            let track1 = URL(fileURLWithPath: "/Music/Track1.mp3")
            let track2 = URL(fileURLWithPath: "/Music/Track2.flac")
            let playlist = Playlist(name: playlistName, trackURLs: [track1, track2])
            
            try service.savePlaylist(playlist)
            
            // 3. List contains saved playlist
            let list = service.listPlaylists()
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list.first?.name, playlistName)
            XCTAssertEqual(list.first?.trackURLs, [track1, track2])
            
            // 4. Delete playlist
            try service.deletePlaylist(name: playlistName)
            XCTAssertTrue(service.listPlaylists().isEmpty)
        }
    }

    func testExport() throws {
        try withTemporaryDirectory(prefix: "PlaylistServiceTests") { tempDir in
            let mockFM = MockFileManager(appSupportURL: tempDir)
            let service = PlaylistService(fileManager: mockFM)

            let playlist = Playlist(name: "ExportTest", trackURLs: [URL(fileURLWithPath: "/Music/Song.m4a")])

            let exportURL = tempDir.appendingPathComponent("exported.m3u")
            try service.exportPlaylist(playlist, to: exportURL)

            XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
            let loaded = try service.loadPlaylist(from: exportURL)
            XCTAssertEqual(loaded.name, "exported")
            XCTAssertEqual(loaded.trackURLs, [URL(fileURLWithPath: "/Music/Song.m4a")])
        }
    }
}
#endif
