import Foundation

/// Identifies an audio CD from its table of contents.
///
/// This is a different kind of lookup from `MetadataMatchService`: that one
/// scores fuzzy text matches and needs usable tags to work from. A CD has none —
/// so this queries MusicBrainz by disc ID, which either matches a pressing
/// exactly or doesn't match at all. No scoring, no threshold, no confidence gate.
///
/// One disc ID can legitimately map to several releases: a standalone album and
/// the same disc inside a box set share a TOC. That is a real choice about what
/// the album tag should say, so every match is returned and the caller picks.
public protocol CDDiscLookup: Sendable {
    func lookup(toc: CompactDiscTOC) async throws -> [ReleaseCandidate]
}

public enum CDDiscLookupError: Error, LocalizedError, Equatable {
    /// The TOC is valid but MusicBrainz has never seen this pressing.
    case discNotFound
    case badStatus(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .discNotFound:
            return "This disc isn’t in the MusicBrainz database yet."
        case .badStatus(let code):
            return "MusicBrainz returned HTTP \(code)."
        case .network(let detail):
            return "Couldn’t reach MusicBrainz: \(detail)"
        }
    }
}

public actor MusicBrainzDiscClient: CDDiscLookup {
    private static let host = "https://musicbrainz.org/ws/2"
    private let session: URLSession
    /// MusicBrainz enforces ~1 request/second per client: the app-wide gate.
    private let gate: MusicBrainzGate

    public init(session: URLSession? = nil, gate: MusicBrainzGate = .shared) {
        self.session = session ?? ReleaseProviderSupport.makeSession()
        self.gate = gate
    }

    public func lookup(toc: CompactDiscTOC) async throws -> [ReleaseCandidate] {
        guard let url = Self.lookupURL(discID: toc.musicBrainzDiscID) else { return [] }
        await throttle()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: ReleaseProviderSupport.request(url))
        } catch {
            throw CDDiscLookupError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CDDiscLookupError.network("no HTTP response")
        }
        // MusicBrainz answers an unknown but well-formed disc ID with 404, which
        // is a normal outcome here, not a failure.
        if http.statusCode == 404 { throw CDDiscLookupError.discNotFound }
        guard (200..<300).contains(http.statusCode) else {
            throw CDDiscLookupError.badStatus(http.statusCode)
        }
        return Self.parse(data)
    }

    /// `inc=recordings+artist-credits` brings the track list and album artist
    /// back in the same request — without it the response names the release but
    /// none of its tracks, which is most of what a rip needs.
    static func lookupURL(discID: String) -> URL? {
        guard !discID.isEmpty else { return nil }
        var components = URLComponents(string: "\(host)/discid/\(discID)")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "recordings+artist-credits")
        ]
        return components?.url
    }

    /// The web page for attaching an unknown disc to a release, so a miss is a
    /// dead end the user can actually do something about.
    public static func submissionURL(for toc: CompactDiscTOC) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/cdtoc/attach")
        components?.queryItems = [
            URLQueryItem(name: "id", value: toc.musicBrainzDiscID),
            URLQueryItem(name: "tracks", value: String(toc.trackCount)),
            URLQueryItem(name: "toc", value: toc.musicBrainzTOCParameter)
        ]
        return components?.url
    }

    static func parse(_ data: Data) -> [ReleaseCandidate] {
        guard let payload = try? JSONDecoder().decode(DiscResponse.self, from: data) else { return [] }
        return (payload.releases ?? []).compactMap { release -> ReleaseCandidate? in
            guard let id = release.id, let title = release.title else { return nil }

            var tracks: [ReleaseTrack] = []
            for medium in release.media ?? [] {
                let disc = medium.position ?? 1
                for track in medium.tracks ?? [] {
                    tracks.append(ReleaseTrack(
                        position: track.position ?? (tracks.count + 1),
                        discNumber: disc,
                        title: track.title,
                        artist: track.artistCredit?.joined,
                        durationSeconds: track.length.map { Double($0) / 1000.0 }
                    ))
                }
            }

            return ReleaseCandidate(
                source: .musicBrainz,
                providerID: id,
                title: title,
                artist: release.artistCredit?.joined ?? "",
                year: ReleaseProviderSupport.year(fromDate: release.date),
                genre: nil,
                totalTracks: tracks.isEmpty ? nil : tracks.count,
                totalDiscs: release.media?.count,
                tracks: tracks,
                // Cover Art Archive serves by release MBID; front=true redirects
                // to whatever image is flagged as the cover.
                artworkURL: URL(string: "https://coverartarchive.org/release/\(id)/front")
            )
        }
    }

    private func throttle() async {
        try? await gate.wait()
    }

    // MARK: - Wire format

    struct DiscResponse: Decodable {
        let releases: [Release]?
    }

    struct Release: Decodable {
        let id: String?
        let title: String?
        let date: String?
        let country: String?
        let media: [Medium]?
        let artistCredit: [MusicBrainzReleaseClient.ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, title, date, country, media
            case artistCredit = "artist-credit"
        }
    }

    struct Medium: Decodable {
        let position: Int?
        let tracks: [Track]?
    }

    struct Track: Decodable {
        let position: Int?
        let title: String
        let length: Int?
        let artistCredit: [MusicBrainzReleaseClient.ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case position, title, length
            case artistCredit = "artist-credit"
        }
    }
}
