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
            
            // 4. Load playlist directly
            let playlistURL = service.getPlaylistsDirectory().appendingPathComponent(playlistName).appendingPathExtension("m3u")
            let loaded = try service.loadPlaylist(from: playlistURL)
            XCTAssertEqual(loaded.name, playlistName)
            XCTAssertEqual(loaded.trackURLs, [track1, track2])
            
            // 5. Delete playlist
            try service.deletePlaylist(name: playlistName)
            XCTAssertTrue(service.listPlaylists().isEmpty)
        }
    }
    
    func testExportAndImport() throws {
        try withTemporaryDirectory(prefix: "PlaylistServiceTests") { tempDir in
            let mockFM = MockFileManager(appSupportURL: tempDir)
            let service = PlaylistService(fileManager: mockFM)
            
            let playlistName = "ImportExportTest"
            let track1 = URL(fileURLWithPath: "/Music/Song.m4a")
            let playlist = Playlist(name: playlistName, trackURLs: [track1])
            
            // Export to a custom location
            let exportURL = tempDir.appendingPathComponent("exported.m3u")
            try service.exportPlaylist(playlist, to: exportURL)
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
            
            // Import playlist
            let imported = try service.importPlaylist(from: exportURL)
            XCTAssertEqual(imported.name, "exported")
            XCTAssertEqual(imported.trackURLs, [track1])
            
            // Should be in main list now
            let list = service.listPlaylists()
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list.first?.name, "exported")
        }
    }
}
#endif
