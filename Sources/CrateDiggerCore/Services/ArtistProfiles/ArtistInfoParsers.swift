import Foundation

/// Reads the answers an artist lookup chains: a MusicBrainz artist search, a
/// MusicBrainz artist lookup (type, areas, life-span, members, genres, its
/// Wikidata relation and release groups), a Wikidata entity's sitelinks, and
/// a Wikipedia REST page summary. Any body that is not the JSON object it
/// should be throws `ArtistPictureSourceError.malformed`.
public enum ArtistInfoParsers {
    /// How many genres a profile keeps, most voted first.
    static let genreCount = 5
    /// The MusicBrainz relation that lists a group's members, read on the
    /// group's own page (the person is "member of" the group: backward).
    static let memberRelation = "member of band"

    /// `/ws/2/artist?query=…&fmt=json`: every artist with an id and a name,
    /// in MusicBrainz's order (best score first). Release titles are not in
    /// a search answer; the lookup of each candidate brings them.
    public static func searchCandidates(_ data: Data) throws -> [ArtistIdentityCandidate] {
        guard let rows = try object(data)["artists"] as? [Any] else { throw ArtistPictureSourceError.malformed }
        return rows.compactMap { row in
            guard let row = row as? [String: Any], let id = text(row["id"]), let name = text(row["name"]) else {
                return nil
            }
            return ArtistIdentityCandidate(musicBrainzID: id, name: name, disambiguation: text(row["disambiguation"]),
                                           origin: origin(row))
        }
    }

    /// `/ws/2/artist/<id>?inc=url-rels+artist-rels+genres+release-groups&fmt=json`.
    /// The facts carry no bio (that is Wikipedia's) and link only the artist's
    /// MusicBrainz page; the lookup adds the Wikipedia link when it finds a bio.
    public static func artistDetail(_ data: Data) throws
        -> (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String]) {
        let artist = try object(data)
        let lifeSpan = artist["life-span"] as? [String: Any]
        let links = text(artist["id"]).flatMap(musicBrainzPage).map { [ArtistLink(kind: .musicBrainz, url: $0)] }
        let facts = ArtistFacts(kind: text(artist["type"]), origin: origin(artist),
                                begin: year(lifeSpan?["begin"]), end: year(lifeSpan?["end"]),
                                members: members(artist), genres: genres(artist), links: links)
        return (facts, try CommonsArtistParser.wikidataID(fromArtist: data),
                try CommonsArtistParser.releaseGroupTitles(fromArtist: data))
    }

    /// The `sitelinks` of entity `id` as site → title (`"enwiki": "Massive
    /// Attack"`). Wikidata answers a merged item under its new id, so a lone
    /// entity of another id is read too.
    public static func wikipediaTitles(fromEntity data: Data, id: String) throws -> [String: String] {
        guard let entities = try object(data)["entities"] as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        let entity = (entities[id] ?? (entities.count == 1 ? entities.values.first : nil)) as? [String: Any]
        let sitelinks = entity?["sitelinks"] as? [String: Any] ?? [:]
        var titles: [String: String] = [:]
        for (site, link) in sitelinks {
            if let title = text((link as? [String: Any])?["title"]) { titles[site] = title }
        }
        return titles
    }

    /// A Wikipedia REST `page/summary` answer: the lead paragraph of its
    /// extract and the article's own page, for the credit. nil for an answer
    /// that is not an article (a "not found" error body, a disambiguation
    /// page), has no text, or links anywhere but Wikipedia: text that cannot
    /// carry its credit is not shown.
    public static func summary(_ data: Data) throws -> (extract: String, pageURL: URL)? {
        let page = try object(data)
        guard page["type"] as? String == "standard",
              let extract = text(page["extract"])?.components(separatedBy: .newlines)
                  .lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
              let address = text(((page["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"]),
              let pageURL = URL(string: address), isWikipedia(pageURL)
        else { return nil }
        return (extract, pageURL)
    }

    /// The Wikipedia to read: the first of `preferredLanguages` (the
    /// language code only, `pt-BR` reads as `pt`) whose `<code>wiki` sitelink
    /// exists, else English, else nil. Pass `Locale.preferredLanguages`.
    public static func wikipediaChoice(sitelinks: [String: String],
                                       preferredLanguages: [String]) -> (language: String, title: String)? {
        let codes = preferredLanguages.compactMap(languageCode) + ["en"]
        for code in codes {
            if let title = sitelinks[code + "wiki"] { return (code, title) }
        }
        return nil
    }

    // MARK: Private

    /// The language part of a BCP 47 tag, lowercased: `pt-BR` gives `pt`.
    static func languageCode(_ tag: String) -> String? {
        let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return !code.isEmpty && code.allSatisfy({ $0.isASCII && $0.isLetter }) ? code : nil
    }

    /// HTTPS on a Wikipedia host the fetcher allows.
    static func isWikipedia(_ url: URL) -> Bool {
        URLSessionPictureFetcher.isAllowed(url) && url.host?.lowercased().hasSuffix(".wikipedia.org") == true
    }

    private static func musicBrainzPage(_ id: String) -> URL? {
        URL(string: "https://musicbrainz.org/artist/" + ArtistPictureURLText.encoded(id))
    }

    /// The begin area (often the city), then the area (often the country),
    /// joined ", "; one of them alone when the other is missing or the same.
    private static func origin(_ artist: [String: Any]) -> String? {
        var parts: [String] = []
        for key in ["begin-area", "area"] {
            guard let name = text((artist[key] as? [String: Any])?["name"]),
                  !parts.contains(where: { PodBoxArtName.folded($0) == PodBoxArtName.folded(name) })
            else { continue }
            parts.append(name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The year of a MusicBrainz partial date: `1991-04-08`, `1991-04` and `1991` give `1991`.
    private static func year(_ value: Any?) -> String? {
        guard let date = text(value) else { return nil }
        let year = String(date.prefix { $0 != "-" })
        return year.isEmpty || !year.allSatisfy(\.isNumber) ? nil : year
    }

    /// Members from backward "member of band" relations, one per person
    /// (a member with two stints shows once, current if either stint is),
    /// current members first, then by the year they joined, then by name.
    /// A stint is current when it has no end date and is not marked ended.
    private static func members(_ artist: [String: Any]) -> [ArtistMember]? {
        let relations = artist["relations"] as? [Any] ?? []
        var byPerson: [String: ArtistMember] = [:]
        var order: [String] = []
        for case let relation as [String: Any] in relations
        where relation["type"] as? String == memberRelation && relation["direction"] as? String == "backward" {
            let person = relation["artist"] as? [String: Any]
            guard let name = text(person?["name"]) else { continue }
            let key = text(person?["id"]) ?? name
            let begin = year(relation["begin"]), end = year(relation["end"])
            let stint = ArtistMember(name: name, begin: begin, end: end,
                                     isCurrent: end == nil && relation["ended"] as? Bool != true)
            guard let known = byPerson[key] else {
                byPerson[key] = stint
                order.append(key)
                continue
            }
            let isCurrent = known.isCurrent || stint.isCurrent
            byPerson[key] = ArtistMember(
                name: known.name, begin: [known.begin, stint.begin].compactMap { $0 }.min(),
                end: isCurrent ? nil : [known.end, stint.end].compactMap { $0 }.max(), isCurrent: isCurrent)
        }
        guard !order.isEmpty else { return nil }
        return order.compactMap { byPerson[$0] }.sorted { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            if a.begin != b.begin { return (a.begin ?? "9999") < (b.begin ?? "9999") }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The top genres by vote count, ties by name; nil when there are none.
    private static func genres(_ artist: [String: Any]) -> [String]? {
        let rows = (artist["genres"] as? [Any] ?? []).compactMap { row -> (name: String, count: Int)? in
            guard let row = row as? [String: Any], let name = text(row["name"]) else { return nil }
            return (name, (row["count"] as? NSNumber)?.intValue ?? 0)
        }
        let top = rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(genreCount).map(\.name)
        return top.isEmpty ? nil : top
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        return object
    }

    /// A trimmed, non-empty string; nil for anything else (including JSON null).
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
