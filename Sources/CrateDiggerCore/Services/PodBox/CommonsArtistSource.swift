import Foundation

/// Reads the three answers the Commons source chains: a MusicBrainz artist
/// search, a MusicBrainz artist lookup (its `wikidata` relation), a
/// release-group browse (the artist's albums and EPs) and a Wikidata entity
/// (property P18, the image). Any body
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

    /// `/ws/2/artist/<id>?inc=url-rels`: the Q number of its `wikidata`
    /// relation, or nil.
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

    /// The titles under `release-groups`: of a release-group browse
    /// (`/ws/2/release-group?artist=<id>`), or of an artist lookup with
    /// `inc=release-groups` (which MusicBrainz caps at 25, singles included).
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

    /// The credit Commons states for a file (`prop=imageinfo&iiprop=extmetadata`):
    /// its short licence name and its author, HTML tags removed.
    public static func credit(fromImageInfo data: Data, fileName: String) throws -> ArtistPictureCredit {
        guard let pages = (try object(data)["query"] as? [String: Any])?["pages"] as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        let page = pages.values.first as? [String: Any]
        let info = (page?["imageinfo"] as? [Any])?.first as? [String: Any]
        let meta = info?["extmetadata"] as? [String: Any]
        func field(_ key: String) -> String? {
            guard let raw = (meta?[key] as? [String: Any])?["value"] as? String else { return nil }
            let plain = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return plain.isEmpty ? nil : plain
        }
        return ArtistPictureCredit(fileName: fileName, licence: field("LicenseShortName"), author: field("Artist"))
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
/// more, each looked up for its Wikidata item, then the item's image (P18).
/// An artist with no Wikidata relation or no image gives no candidate. The
/// album titles of the D2 cross-check are browsed only when the finder asks
/// (`albumTitles(for:)`), which it does only for a name that matches.
///
/// MusicBrainz asks for at most one request a second per client: its calls
/// here wait at `MusicBrainzGate.shared`, the gate every MusicBrainz caller
/// in the app shares, and a 503 (its rate limiter) is tried once more after
/// its next slot. They wait in the lane the caller passes
/// (`candidates(for:lane:)`), foreground unless the background artist lookup
/// says otherwise. Each candidate carries its Commons file name, licence and
/// author. Used only by the background job and the Artist Pictures sheet,
/// never inside a transfer.
public struct CommonsArtistSource: ArtistPictureSource {
    public var id: ArtistPictureSourceID { .commons }

    static let minimumScore = 90
    static let lookedUp = 3

    private let fetcher: ArtistPictureFetching
    private let musicBrainz: MusicBrainzGate

    public init(fetcher: ArtistPictureFetching, musicBrainzGate: MusicBrainzGate = .shared) {
        self.fetcher = fetcher
        musicBrainz = musicBrainzGate
    }

    public func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
        try await candidates(for: name, lane: .foreground)
    }

    public func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistPictureCandidate] {
        let found = try CommonsArtistParser.musicBrainzArtists(try await musicBrainzData(Self.searchURL(name: name),
                                                                                         lane: lane))
        var candidates: [ArtistPictureCandidate] = []
        for artist in found.filter({ $0.score >= Self.minimumScore }).prefix(Self.lookedUp) {
            let details = try await musicBrainzData(Self.artistURL(id: artist.id), lane: lane)
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
                credit: try await credit(for: file)))
        }
        return candidates
    }

    /// The artist's albums and EPs, from one release-group browse. Not the
    /// lookup's `inc=release-groups`: MusicBrainz caps that at 25 with
    /// singles counted, so a prolific act's albums can fall outside it.
    public func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] {
        try await albumTitles(for: candidate, lane: .foreground)
    }

    public func albumTitles(for candidate: ArtistPictureCandidate, lane: MusicBrainzGate.Lane) async throws -> [String] {
        guard candidate.albumTitles.isEmpty else { return candidate.albumTitles }
        return try CommonsArtistParser.releaseGroupTitles(
            fromArtist: try await musicBrainzData(Self.releaseGroupsURL(artistID: candidate.sourceID), lane: lane))
    }

    /// `https://musicbrainz.org/ws/2/artist?query=artist:"<name>"&fmt=json&limit=<limit>`,
    /// the name escaped for MusicBrainz's query syntax.
    static func searchURL(name: String, limit: Int = 5) -> URL {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query = ArtistPictureURLText.encoded("artist:\"\(escaped)\"")
        return URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&fmt=json&limit=\(limit)")!
    }

    static func artistURL(id: String) -> URL {
        URL(string: "https://musicbrainz.org/ws/2/artist/\(ArtistPictureURLText.encoded(id))?inc=url-rels&fmt=json")!
    }

    /// `https://musicbrainz.org/ws/2/release-group?artist=<id>&type=album|ep&limit=100&fmt=json`:
    /// one page of an artist's albums and EPs (`|` sent as `%7C`).
    static func releaseGroupsURL(artistID: String) -> URL {
        URL(string: "https://musicbrainz.org/ws/2/release-group?artist=\(ArtistPictureURLText.encoded(artistID))"
            + "&type=album%7Cep&limit=100&fmt=json")!
    }

    /// `https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=extmetadata&titles=File:<name>`.
    static func imageInfoURL(fileName: String) -> URL {
        let title = ArtistPictureURLText.encoded("File:" + fileName.replacingOccurrences(of: " ", with: "_"))
        return URL(string: "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=extmetadata&titles=\(title)")!
    }

    /// The file's credit. An answer that is missing or not what Commons
    /// documents keeps the file name alone; a failure that stops the run
    /// (offline, a 5xx) is thrown.
    private func credit(for fileName: String) async throws -> ArtistPictureCredit {
        let bare = ArtistPictureCredit(fileName: fileName)
        let data: Data
        do {
            data = try await fetcher.data(from: Self.imageInfoURL(fileName: fileName))
        } catch {
            if let source = ArtistPictureSourceError.reading(error), !source.stopsTheRun { return bare }
            throw error
        }
        return (try? CommonsArtistParser.credit(fromImageInfo: data, fileName: fileName)) ?? bare
    }

    static func entityURL(id: String) -> URL {
        URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(ArtistPictureURLText.encoded(id)).json")!
    }

    private func musicBrainzData(_ url: URL, lane: MusicBrainzGate.Lane) async throws -> Data {
        try await musicBrainz.wait(lane: lane)
        do {
            return try await fetcher.data(from: url)
        } catch ArtistPictureSourceError.http(503) {
            try await musicBrainz.wait(lane: lane)
            return try await fetcher.data(from: url)
        }
    }
}
