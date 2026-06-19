import Foundation
import CommonCrypto

public struct SubsonicArtist: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var albumCount: Int?
}

public struct SubsonicAlbum: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let artistId: String?
    public let songCount: Int?
    public let duration: Int?
    public let year: Int?
    public let coverArt: String?
}

public struct SubsonicTrack: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let track: Int?
    public let duration: Int?
    public let bitRate: Int?
    public let sampleRate: Int?
    public let suffix: String?
    public let size: Int64?
    public let coverArt: String?
}

public final class SubsonicClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private func md5(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func buildURL(endpoint: String, config: SubsonicConfig, extraParams: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: config.url) else { return nil }
        
        // Ensure path ends with /rest/<endpoint>
        var path = components.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        if !path.contains("/rest/") {
            path += "rest/"
        }
        path += endpoint
        components.path = path

        let salt = UUID().uuidString.prefix(8).lowercased()
        let token = md5(config.password + salt)

        var queryItems = [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "cratedigger"),
            URLQueryItem(name: "f", value: "json")
        ]
        queryItems.append(contentsOf: extraParams)
        components.queryItems = queryItems
        
        return components.url
    }

    public func ping(config: SubsonicConfig) async throws -> Bool {
        guard let url = buildURL(endpoint: "ping.view", config: config) else {
            return false
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return false
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let subsonicResponse = json["subsonic-response"] as? [String: Any],
           let status = subsonicResponse["status"] as? String {
            return status == "ok"
        }
        return false
    }

    public func getArtists(config: SubsonicConfig) async throws -> [SubsonicArtist] {
        guard let url = buildURL(endpoint: "getArtists.view", config: config) else {
            return []
        }
        let (data, _) = try await session.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subsonicResponse = json["subsonic-response"] as? [String: Any],
              let artistsContainer = subsonicResponse["artists"] as? [String: Any],
              let indexArray = artistsContainer["index"] as? [[String: Any]] else {
            return []
        }

        var artists: [SubsonicArtist] = []
        for index in indexArray {
            if let artistList = index["artist"] as? [[String: Any]] {
                for art in artistList {
                    if let id = art["id"] as? String,
                       let name = art["name"] as? String {
                        artists.append(SubsonicArtist(id: id, name: name, albumCount: art["albumCount"] as? Int))
                    }
                }
            }
        }
        return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func getArtist(id: String, config: SubsonicConfig) async throws -> [SubsonicAlbum] {
        guard let url = buildURL(endpoint: "getArtist.view", config: config, extraParams: [URLQueryItem(name: "id", value: id)]) else {
            return []
        }
        let (data, _) = try await session.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subsonicResponse = json["subsonic-response"] as? [String: Any],
              let artistContainer = subsonicResponse["artist"] as? [String: Any],
              let albumList = artistContainer["album"] as? [[String: Any]] else {
            return []
        }

        return albumList.compactMap { alb -> SubsonicAlbum? in
            guard let id = alb["id"] as? String,
                  let name = alb["name"] as? String,
                  let artist = alb["artist"] as? String else {
                return nil
            }
            return SubsonicAlbum(
                id: id,
                name: name,
                artist: artist,
                artistId: alb["artistId"] as? String,
                songCount: alb["songCount"] as? Int,
                duration: alb["duration"] as? Int,
                year: alb["year"] as? Int,
                coverArt: alb["coverArt"] as? String
            )
        }
    }

    public func getAlbum(id: String, config: SubsonicConfig) async throws -> [SubsonicTrack] {
        guard let url = buildURL(endpoint: "getAlbum.view", config: config, extraParams: [URLQueryItem(name: "id", value: id)]) else {
            return []
        }
        let (data, _) = try await session.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subsonicResponse = json["subsonic-response"] as? [String: Any],
              let albumContainer = subsonicResponse["album"] as? [String: Any],
              let songList = albumContainer["song"] as? [[String: Any]] else {
            return []
        }

        return songList.compactMap { song -> SubsonicTrack? in
            guard let id = song["id"] as? String,
                  let title = song["title"] as? String,
                  let artist = song["artist"] as? String,
                  let album = song["album"] as? String else {
                return nil
            }
            return SubsonicTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                track: song["track"] as? Int,
                duration: song["duration"] as? Int,
                bitRate: song["bitRate"] as? Int,
                sampleRate: song["sampleRate"] as? Int,
                suffix: song["suffix"] as? String,
                size: song["size"] as? Int64,
                coverArt: song["coverArt"] as? String
            )
        }
    }

    public func streamURL(forTrackID trackID: String, config: SubsonicConfig) -> URL? {
        buildURL(endpoint: "stream.view", config: config, extraParams: [
            URLQueryItem(name: "id", value: trackID),
            URLQueryItem(name: "maxBitRate", value: "320")
        ])
    }

    public func coverArtURL(forCoverArtID artID: String, config: SubsonicConfig, size: Int = 300) -> URL? {
        buildURL(endpoint: "getCoverArt.view", config: config, extraParams: [
            URLQueryItem(name: "id", value: artID),
            URLQueryItem(name: "size", value: String(size))
        ])
    }
}
