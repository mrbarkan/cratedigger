import Foundation
import CryptoKit

public final class LastFMScrobbler: Sendable {
    private let apiKey = "141b714fa4cf3c40f1a92e622b7a9ef0"
    private let apiSecret = "8d30e3ff4db24718cd92b236113b2c6c"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MD5 here is the Last.fm API signature scheme (api_sig), not a security
    // hash — the protocol mandates it. Insecure.MD5 is the non-deprecated API.
    private func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }

    private func calculateSignature(params: [String: String]) -> String {
        let sortedKeys = params.keys.sorted()
        var signatureString = ""
        for key in sortedKeys {
            if let val = params[key] {
                signatureString += key + val
            }
        }
        signatureString += apiSecret
        return md5(signatureString)
    }

    private func postRequest(method: String, params: [String: String]) async throws -> [String: Any]? {
        var allParams = params
        allParams["method"] = method
        allParams["api_key"] = apiKey
        allParams["api_sig"] = calculateSignature(params: allParams)
        allParams["format"] = "json"

        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func getAuthorizationURL() -> URL? {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)")
    }

    public func fetchSession(token: String) async throws -> (username: String, sessionKey: String)? {
        let params = ["token": token]
        guard let json = try await postRequest(method: "auth.getSession", params: params),
              let session = json["session"] as? [String: Any],
              let username = session["name"] as? String,
              let sessionKey = session["key"] as? String else {
            return nil
        }
        return (username, sessionKey)
    }

    public func updateNowPlaying(artist: String, track: String, album: String?, sessionKey: String) async throws -> Bool {
        var params = [
            "artist": artist,
            "track": track,
            "sk": sessionKey
        ]
        if let album {
            params["album"] = album
        }

        let result = try await postRequest(method: "track.updateNowPlaying", params: params)
        return result != nil
    }

    public func scrobble(artist: String, track: String, album: String?, timestamp: Int, sessionKey: String) async throws -> Bool {
        var params = [
            "artist": artist,
            "track": track,
            "timestamp": String(timestamp),
            "sk": sessionKey
        ]
        if let album {
            params["album"] = album
        }

        let result = try await postRequest(method: "track.scrobble", params: params)
        return result != nil
    }
}
