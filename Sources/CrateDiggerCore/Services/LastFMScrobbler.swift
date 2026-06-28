import Foundation
import CryptoKit

public final class LastFMScrobbler: Sendable {
    private let credentials: LastFMCredentials?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        self.credentials = LastFMCredentialsResolver.resolveDefault()
    }

    /// Injection seam for tests / dev tooling. Internal so it never becomes
    /// part of the public API surface.
    init(session: URLSession, credentials: LastFMCredentials?) {
        self.session = session
        self.credentials = credentials
    }

    /// `true` when application API credentials are available. When `false`,
    /// every network method below no-ops (returns `nil`/`false`) so the app
    /// runs fine without Last.fm configured.
    public var isConfigured: Bool { credentials != nil }

    // MD5 here is the Last.fm API signature scheme (api_sig), not a security
    // hash — the protocol mandates it. Insecure.MD5 is the non-deprecated API.
    private func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).hexString
    }

    private func calculateSignature(params: [String: String], secret: String) -> String {
        let sortedKeys = params.keys.sorted()
        var signatureString = ""
        for key in sortedKeys {
            if let val = params[key] {
                signatureString += key + val
            }
        }
        signatureString += secret
        return md5(signatureString)
    }

    private func postRequest(method: String, params: [String: String]) async throws -> [String: Any]? {
        guard let credentials else { return nil }

        var allParams = params
        allParams["method"] = method
        allParams["api_key"] = credentials.apiKey
        allParams["api_sig"] = calculateSignature(params: allParams, secret: credentials.apiSecret)
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
        guard let credentials else { return nil }
        return URL(string: "https://www.last.fm/api/auth/?api_key=\(credentials.apiKey)")
    }

    /// Fetches a fresh request token for the desktop web-auth flow.
    /// Returns `nil` when Last.fm is not configured or the request fails.
    public func fetchRequestToken() async throws -> String? {
        guard let credentials else { return nil }
        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/?method=auth.getToken&api_key=\(credentials.apiKey)&format=json") else {
            return nil
        }
        let (data, _) = try await session.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            return nil
        }
        return token
    }

    /// Web-auth URL the user opens to authorize a specific request token.
    public func authorizationURL(forToken token: String) -> URL? {
        guard let credentials else { return nil }
        return URL(string: "https://www.last.fm/api/auth/?api_key=\(credentials.apiKey)&token=\(token)")
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
