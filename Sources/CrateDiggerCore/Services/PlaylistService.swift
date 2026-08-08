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

    /// Rename a playlist file on disk (`<old>.m3u` → `<new>.m3u`). Throws if the
    /// source is missing or a different playlist already uses the new name.
    public func renamePlaylist(from oldName: String, to newName: String) throws {
        let src = playlistsDirectoryURL.appendingPathComponent(oldName).appendingPathExtension("m3u")
        let dest = playlistsDirectoryURL.appendingPathComponent(newName).appendingPathExtension("m3u")
        guard fileManager.fileExists(atPath: src.path) else { throw CocoaError(.fileNoSuchFile) }

        // On case-insensitive volumes a case-only rename needs a temp hop so the
        // move isn't treated as "destination already exists".
        let caseOnly = oldName.lowercased() == newName.lowercased()
        if !caseOnly && fileManager.fileExists(atPath: dest.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        if caseOnly {
            let tmp = playlistsDirectoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("m3u")
            try fileManager.moveItem(at: src, to: tmp)
            try fileManager.moveItem(at: tmp, to: dest)
        } else {
            try fileManager.moveItem(at: src, to: dest)
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
}

public extension Playlist {
    /// A playlist's order *is* its content, so reordering has to be exact.
    ///
    /// Returns `urls` with every entry in `moving` lifted out and reinserted
    /// immediately before `destination`, keeping the moved entries in the order
    /// they appeared. A nil `destination` (or one that is itself being moved)
    /// appends them at the end.
    static func reordered(_ urls: [URL], moving: [URL], before destination: URL?) -> [URL] {
        let movingSet = Set(moving.map(\.standardizedFileURL))
        guard !movingSet.isEmpty else { return urls }

        // Keep the list's own order for the moved run, not the order they were
        // clicked in — a drag of rows 3, 7, 5 lands as 3, 5, 7.
        let lifted = urls.filter { movingSet.contains($0.standardizedFileURL) }
        let remaining = urls.filter { !movingSet.contains($0.standardizedFileURL) }

        guard let destination,
              !movingSet.contains(destination.standardizedFileURL),
              let insertAt = remaining.firstIndex(where: {
                  $0.standardizedFileURL == destination.standardizedFileURL
              })
        else { return remaining + lifted }

        var result = remaining
        result.insert(contentsOf: lifted, at: insertAt)
        return result
    }
}
