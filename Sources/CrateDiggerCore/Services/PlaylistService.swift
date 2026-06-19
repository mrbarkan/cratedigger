import Foundation

public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public var trackURLs: [URL]

    public init(name: String, trackURLs: [URL] = []) {
        self.name = name
        self.trackURLs = trackURLs
    }
}

public final class PlaylistService {
    private let fileManager: FileManager
    private let playlistsDirectoryURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("CrateDigger", isDirectory: true)
        self.playlistsDirectoryURL = appDirectory.appendingPathComponent("Playlists", isDirectory: true)
        
        try? fileManager.createDirectory(at: playlistsDirectoryURL, withIntermediateDirectories: true)
    }

    public func getPlaylistsDirectory() -> URL {
        return playlistsDirectoryURL
    }

    public func listPlaylists() -> [Playlist] {
        guard let contents = try? fileManager.contentsOfDirectory(at: playlistsDirectoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return contents
            .filter { $0.pathExtension.lowercased() == "m3u" || $0.pathExtension.lowercased() == "m3u8" }
            .compactMap { try? loadPlaylist(from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func loadPlaylist(from url: URL) throws -> Playlist {
        let content = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        var trackURLs: [URL] = []

        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return }
            
            if trimmed.hasPrefix("file://") {
                if let trackURL = URL(string: trimmed) {
                    trackURLs.append(trackURL)
                }
            } else {
                let trackURL = URL(fileURLWithPath: trimmed)
                trackURLs.append(trackURL)
            }
        }

        return Playlist(name: name, trackURLs: trackURLs)
    }

    public func savePlaylist(_ playlist: Playlist) throws {
        let url = playlistsDirectoryURL.appendingPathComponent(playlist.name).appendingPathExtension("m3u")
        try exportPlaylist(playlist, to: url)
    }

    public func deletePlaylist(name: String) throws {
        let url = playlistsDirectoryURL.appendingPathComponent(name).appendingPathExtension("m3u")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func exportPlaylist(_ playlist: Playlist, to url: URL) throws {
        var lines = ["#EXTM3U"]
        for trackURL in playlist.trackURLs {
            lines.append(trackURL.path)
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func importPlaylist(from url: URL) throws -> Playlist {
        let playlist = try loadPlaylist(from: url)
        try savePlaylist(playlist)
        return playlist
    }
}
