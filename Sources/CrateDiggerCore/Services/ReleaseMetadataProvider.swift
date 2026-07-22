import Foundation

/// A source of release metadata (MusicBrainz, iTunes, …).
///
/// Implementations return candidates *with* their track lists — the search and
/// the detail lookup a source needs are its own business, so the matcher stays
/// free of per-source request choreography. "No results" is an empty array, not
/// an error; only genuine failures (network down, malformed response) throw, and
/// `MetadataMatchService` treats even those as non-fatal so one dead source
/// can't take the whole lookup down with it.
public protocol ReleaseMetadataProvider: Sendable {
    var source: ReleaseSource { get }

    /// Releases that might be what `query` describes, best-first by the source's
    /// own relevance. At most `detailLimit` of them carry full track lists.
    func searchReleases(query: ReleaseQuery, detailLimit: Int) async throws -> [ReleaseCandidate]
}

// MARK: - Shared helpers

enum ReleaseProviderSupport {
    static let userAgent = "CrateDigger/\(AppVersionInfo.short) (https://cratedigger.mrbarkan.com)"

    static func makeSession(timeout: TimeInterval = 12) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2.5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Leading 4-digit year out of "1983", "1983-05-02", "1983-05-02T07:00:00Z".
    static func year(fromDate date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        guard let parsed = Int(date.prefix(4)), (1900...2100).contains(parsed) else { return nil }
        return parsed
    }
}

/// Version string for the User-Agent both sources ask us to send. Read from the
/// bundle when there is one (the packaged app), with a floor for unit tests and
/// the bare debug binary.
enum AppVersionInfo {
    static var short: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1"
    }
}

// MARK: - MusicBrainz

/// MusicBrainz: free, no key, deep release data (track lists, album artists,
/// years). Its rate limit is ~1 request/second for anonymous clients and it is
/// enforced — hence the actor-serialized throttle. A lookup costs one search
/// plus one detail request per inspected candidate, so an album match is a
/// handful of seconds at worst.
public actor MusicBrainzReleaseClient: ReleaseMetadataProvider {
    public nonisolated var source: ReleaseSource { .musicBrainz }

    private static let host = "https://musicbrainz.org/ws/2"
    private static let minimumRequestInterval: TimeInterval = 1.05

    private let session: URLSession
    private var lastRequestAt: Date?

    public init(session: URLSession? = nil) {
        self.session = session ?? ReleaseProviderSupport.makeSession()
    }

    public func searchReleases(query: ReleaseQuery, detailLimit: Int) async throws -> [ReleaseCandidate] {
        guard let searchURL = Self.searchURL(for: query) else { return [] }

        let results: SearchResponse = try await get(searchURL)
        let releases = results.releases ?? []
        guard !releases.isEmpty else { return [] }

        var candidates: [ReleaseCandidate] = []
        for release in releases.prefix(detailLimit) {
            // A detail lookup that fails shouldn't lose the candidate outright:
            // the search result alone still scores on artist/album/track-count.
            if let detailed = try? await detail(for: release) {
                candidates.append(detailed)
            } else {
                candidates.append(release.asCandidate(tracks: []))
            }
        }
        return candidates
    }

    static func searchURL(for query: ReleaseQuery) -> URL? {
        var parts: [String] = []
        if let artist = query.artist, !artist.isEmpty {
            parts.append("artist:\(lucene(artist))")
        }
        if let album = query.album, !album.isEmpty {
            parts.append("release:\(lucene(album))")
        } else if let title = query.tracks.compactMap({ $0.title }).first, !title.isEmpty {
            // No album name to go on (an untagged rip): a track title at least
            // aims the search at the right release group.
            parts.append("recording:\(lucene(title))")
        }
        guard !parts.isEmpty else { return nil }

        var components = URLComponents(string: "\(host)/release/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: parts.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    /// Quote a term for Lucene, escaping the characters that would otherwise
    /// change the query's meaning (an album literally called "AND" or one with a
    /// quote in it must not break the search).
    private static func lucene(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func detail(for release: SearchRelease) async throws -> ReleaseCandidate {
        var components = URLComponents(string: "\(Self.host)/release/\(release.id)")
        components?.queryItems = [
            URLQueryItem(name: "inc", value: "recordings+artist-credits"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components?.url else { return release.asCandidate(tracks: []) }

        let detail: DetailResponse = try await get(url)
        var tracks: [ReleaseTrack] = []
        for medium in detail.media ?? [] {
            let disc = medium.position ?? 1
            for track in medium.tracks ?? [] {
                tracks.append(ReleaseTrack(
                    position: track.position ?? tracks.count + 1,
                    discNumber: disc,
                    title: track.title,
                    artist: track.artistCredit?.joined,
                    durationSeconds: track.length.map { Double($0) / 1000 }
                ))
            }
        }
        let discCount = (detail.media?.count).flatMap { $0 > 0 ? $0 : nil }
        return release.asCandidate(tracks: tracks, totalDiscs: discCount)
    }

    /// Serialized through the actor, so the sleep genuinely spaces requests
    /// rather than letting a burst race past it.
    private func get<T: Decodable>(_ url: URL) async throws -> T {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumRequestInterval {
                try await Task.sleep(nanoseconds: UInt64((Self.minimumRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()

        let (data, response) = try await session.data(for: ReleaseProviderSupport.request(url))
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseLookupError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Wire format

    struct SearchResponse: Decodable {
        let releases: [SearchRelease]?
    }

    struct SearchRelease: Decodable {
        let id: String
        let title: String
        let date: String?
        let trackCount: Int?
        let artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, title, date
            case trackCount = "track-count"
            case artistCredit = "artist-credit"
        }

        func asCandidate(tracks: [ReleaseTrack], totalDiscs: Int? = nil) -> ReleaseCandidate {
            ReleaseCandidate(
                source: .musicBrainz,
                providerID: id,
                title: title,
                artist: artistCredit?.joined ?? "",
                year: ReleaseProviderSupport.year(fromDate: date),
                // MusicBrainz models genre as community tags, which are noisy and
                // cost another request; iTunes covers genre well enough that
                // guessing here isn't worth it.
                genre: nil,
                totalTracks: trackCount ?? (tracks.isEmpty ? nil : tracks.count),
                totalDiscs: totalDiscs,
                tracks: tracks
            )
        }
    }

    struct DetailResponse: Decodable {
        let media: [Medium]?
    }

    struct Medium: Decodable {
        let position: Int?
        let tracks: [Track]?
    }

    struct Track: Decodable {
        let position: Int?
        let title: String
        let length: Int?
        let artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case position, title, length
            case artistCredit = "artist-credit"
        }
    }

    struct ArtistCredit: Decodable {
        let name: String?
        let joinphrase: String?
    }
}

extension Array where Element == MusicBrainzReleaseClient.ArtistCredit {
    /// "Artist A feat. Artist B" — MusicBrainz splits collaborations into credits
    /// joined by their own phrases.
    var joined: String? {
        let text = reduce(into: "") { result, credit in
            result += (credit.name ?? "") + (credit.joinphrase ?? "")
        }.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

// MARK: - iTunes

/// The iTunes Search API: free, no key, fast, and generous with genre — the
/// counterweight to MusicBrainz's depth. One search plus one lookup per
/// inspected album (the search alone has no track list).
public struct ITunesReleaseClient: ReleaseMetadataProvider {
    public var source: ReleaseSource { .iTunes }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ReleaseProviderSupport.makeSession()
    }

    public func searchReleases(query: ReleaseQuery, detailLimit: Int) async throws -> [ReleaseCandidate] {
        guard let searchURL = Self.searchURL(for: query) else { return [] }

        let response: Response = try await get(searchURL)
        let albums = (response.results ?? []).filter { $0.collectionId != nil }
        guard !albums.isEmpty else { return [] }

        var candidates: [ReleaseCandidate] = []
        for album in albums.prefix(detailLimit) {
            guard let id = album.collectionId else { continue }
            let tracks = (try? await songs(collectionID: id)) ?? []
            candidates.append(album.asCandidate(tracks: tracks))
        }
        return candidates
    }

    static func searchURL(for query: ReleaseQuery) -> URL? {
        let term = [query.artist, query.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallbackTerm = query.tracks.compactMap { $0.title }.first ?? ""
        let searchTerm = term.isEmpty ? fallbackTerm : term
        guard !searchTerm.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: searchTerm),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    private func songs(collectionID: Int) async throws -> [ReleaseTrack] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(collectionID)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components?.url else { return [] }

        let response: Response = try await get(url)
        return (response.results ?? [])
            .filter { $0.wrapperType == "track" }
            .compactMap { item in
                guard let title = item.trackName else { return nil }
                return ReleaseTrack(
                    position: item.trackNumber ?? 0,
                    discNumber: item.discNumber ?? 1,
                    title: title,
                    artist: item.artistName,
                    durationSeconds: item.trackTimeMillis.map { Double($0) / 1000 }
                )
            }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(for: ReleaseProviderSupport.request(url))
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseLookupError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Wire format

    struct Response: Decodable {
        let results: [Item]?
    }

    struct Item: Decodable {
        let wrapperType: String?
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let releaseDate: String?
        let primaryGenreName: String?
        let trackCount: Int?
        let discCount: Int?
        let artworkUrl100: String?
        // Song-only fields.
        let trackName: String?
        let trackNumber: Int?
        let discNumber: Int?
        let trackTimeMillis: Int?

        func asCandidate(tracks: [ReleaseTrack]) -> ReleaseCandidate {
            let discs = tracks.isEmpty ? discCount : max(discCount ?? 1, tracks.map(\.discNumber).max() ?? 1)
            return ReleaseCandidate(
                source: .iTunes,
                providerID: collectionId.map(String.init) ?? "",
                title: collectionName ?? "",
                artist: artistName ?? "",
                year: ReleaseProviderSupport.year(fromDate: releaseDate),
                genre: primaryGenreName,
                totalTracks: trackCount ?? (tracks.isEmpty ? nil : tracks.count),
                totalDiscs: discs,
                tracks: tracks,
                artworkURL: artworkUrl100.flatMap(URL.init(string:))
            )
        }
    }
}

public enum ReleaseLookupError: Error, LocalizedError {
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "The metadata service returned HTTP \(code)."
        }
    }
}
