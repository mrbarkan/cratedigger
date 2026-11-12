import Foundation

/// Reads the three answers the Commons source chains: a MusicBrainz artist
/// search, a MusicBrainz artist lookup (its `wikidata` relation and its
/// release groups) and a Wikidata entity (property P18, the image). Any body
/// that is not the JSON object it should be throws `.malformed`.
public enum CommonsArtistParser {
    /// `/ws/2/artist?query=…&fmt=json`.
    public static func musicBrainzArtists(_ data: Data) throws -> [(id: String, name: String, score: Int)] {
        guard let rows = try object(data)["artists"] as? [Any] else { throw ArtistPictureSourceError.malformed }
        return rows.compactMap { row in
            guard let row = row as? [String: Any],
                  let id = row["id"] as? String, !id.isEmpty,
                  let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let score = integer(row["score"])
            else { return nil }
            return (id, name, score)
        }
    }

    /// `/ws/2/artist/<id>?inc=url-rels+release-groups`: the Q number of its
    /// `wikidata` relation, or nil.
    public static func wikidataID(fromArtist data: Data) throws -> String? {
        let relations = try object(data)["relations"] as? [Any] ?? []
        for case let relation as [String: Any] in relations where relation["type"] as? String == "wikidata" {
            guard let resource = (relation["url"] as? [String: Any])?["resource"] as? String,
                  let last = URL(string: resource)?.lastPathComponent, isEntityID(last)
            else { continue }
            return last
        }
        return nil
    }

    public static func releaseGroupTitles(fromArtist data: Data) throws -> [String] {
        let groups = try object(data)["release-groups"] as? [Any] ?? []
        return groups.compactMap { group in
            let title = ((group as? [String: Any])?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        }
    }

    /// `claims.P18[0].mainsnak.datavalue.value` of entity `id`. Wikidata
    /// answers a merged item under its new id, so a lone entity of another id is read too.
    public static func imageFileName(fromEntity data: Data, id: String) throws -> String? {
        guard let entities = try object(data)["entities"] as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        let entity = (entities[id] ?? (entities.count == 1 ? entities.values.first : nil)) as? [String: Any]
        let claims = (entity?["claims"] as? [String: Any])?["P18"] as? [Any]
        let snak = (claims?.first as? [String: Any])?["mainsnak"] as? [String: Any]
        let value = ((snak?["datavalue"] as? [String: Any])?["value"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// `https://commons.wikimedia.org/wiki/Special:FilePath/<name>?width=800`,
    /// the name with spaces as underscores (MediaWiki's own form) and the
    /// rest percent-encoded. Commons scales the picture to `width`.
    public static func imageURL(fileName: String, width: Int = 800) -> URL {
        let name = ArtistPictureURLText.encoded(fileName.replacingOccurrences(of: " ", with: "_"))
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(name)?width=\(width)")!
    }

    // MARK: Private

    static func isEntityID(_ text: String) -> Bool {
        text.count > 1 && text.first == "Q" && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        return object
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }
}

/// Artist pictures from Wikimedia Commons, found through MusicBrainz and
/// Wikidata (phase 2b): the top three MusicBrainz artists scoring 90 or
/// more, each looked up for its Wikidata item and its release groups (the
/// album titles of the D2 cross-check), then the item's image (P18). An
/// artist with no Wikidata relation or no image gives no candidate.
///
/// MusicBrainz asks for at most one request a second: its calls here are at
/// least `musicBrainzSpacing` apart, the slot claimed before sleeping, and a
/// 503 (its rate limiter) is tried once more after the spacing. Used only by
/// the background job and the Artist Pictures sheet, never inside a transfer.
public struct CommonsArtistSource: ArtistPictureSource {
    public var id: ArtistPictureSourceID { .commons }

    static let minimumScore = 90
    static let lookedUp = 3

    private let fetcher: ArtistPictureFetching
    private let musicBrainz: RequestSpacer

    public init(fetcher: ArtistPictureFetching, musicBrainzSpacing: Duration = .seconds(1)) {
        self.fetcher = fetcher
        musicBrainz = RequestSpacer(spacing: musicBrainzSpacing)
    }

    public func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
        let found = try CommonsArtistParser.musicBrainzArtists(try await musicBrainzData(Self.searchURL(name: name)))
        var candidates: [ArtistPictureCandidate] = []
        for artist in found.filter({ $0.score >= Self.minimumScore }).prefix(Self.lookedUp) {
            let details = try await musicBrainzData(Self.artistURL(id: artist.id))
            guard let item = try CommonsArtistParser.wikidataID(fromArtist: details) else { continue }
            let entity: Data
            do {
                entity = try await fetcher.data(from: Self.entityURL(id: item))
            } catch let error as ArtistPictureSourceError {
                if case .http(404) = error { continue } // an item since deleted
                throw error
            }
            guard let file = try CommonsArtistParser.imageFileName(fromEntity: entity, id: item) else { continue }
            candidates.append(ArtistPictureCandidate(
                name: artist.name, source: .commons, sourceID: artist.id,
                imageURL: CommonsArtistParser.imageURL(fileName: file),
                albumTitles: try CommonsArtistParser.releaseGroupTitles(fromArtist: details)))
        }
        return candidates
    }

    /// The lookup already brought the release groups; asking again would
    /// cost a MusicBrainz request for the same answer.
    public func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] {
        candidate.albumTitles
    }

    /// `https://musicbrainz.org/ws/2/artist?query=artist:"<name>"&fmt=json&limit=5`,
    /// the name escaped for MusicBrainz's query syntax.
    static func searchURL(name: String) -> URL {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query = ArtistPictureURLText.encoded("artist:\"\(escaped)\"")
        return URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&fmt=json&limit=5")!
    }

    /// The `+` stays as it is: MusicBrainz separates `inc` values with it.
    static func artistURL(id: String) -> URL {
        URL(string: "https://musicbrainz.org/ws/2/artist/\(ArtistPictureURLText.encoded(id))?inc=url-rels+release-groups&fmt=json")!
    }

    static func entityURL(id: String) -> URL {
        URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(ArtistPictureURLText.encoded(id)).json")!
    }

    private func musicBrainzData(_ url: URL) async throws -> Data {
        try await musicBrainz.wait()
        do {
            return try await fetcher.data(from: url)
        } catch ArtistPictureSourceError.http(503) {
            try await musicBrainz.wait()
            return try await fetcher.data(from: url)
        }
    }
}
