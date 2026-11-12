import Foundation

/// The network half of an artist lookup, behind a protocol so tests and the
/// lookup worker can answer it themselves.
public protocol ArtistInfoFetching: Sendable {
    /// MusicBrainz artists whose name looks like `name`, best score first.
    func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistIdentityCandidate]
    /// One MusicBrainz artist's facts, Wikidata id and release-group titles.
    func detail(musicBrainzID: String, lane: MusicBrainzGate.Lane) async throws
        -> (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String])
    /// The lead paragraph of the artist's Wikipedia article in the first of
    /// `preferredLanguages` that has one, else English; nil when there is none.
    func bio(wikidataID: String, preferredLanguages: [String]) async throws -> (extract: String, pageURL: URL)?
}

/// MusicBrainz, Wikidata and Wikipedia through the artist pictures' fetcher
/// (its HTTPS host allowlist, redirect guard and generic User-Agent). Only an
/// artist's name, its MusicBrainz and Wikidata ids and a Wikipedia article
/// title ever leave the machine.
///
/// Every MusicBrainz request waits at `gate` in the caller's lane, and a 503
/// (its rate limiter) is tried once more after its next slot. Wikidata and
/// Wikipedia requests are kept `wikimediaSpacing` apart.
///
/// Failures are never "nobody found": a transport error, a 5xx or a 429
/// comes out as the fetcher's `ArtistPictureSourceError`, whose `stopsTheRun`
/// tells the worker to back off. Only a missing Wikidata item or Wikipedia
/// page (a 404) reads as "no bio".
public struct ArtistInfoClient: ArtistInfoFetching {
    /// Search results asked for: enough to see every act of a common name.
    static let searchLimit = 10

    private let fetcher: ArtistPictureFetching
    private let gate: MusicBrainzGate
    private let wikimedia: RequestSpacer

    public init(fetcher: ArtistPictureFetching, gate: MusicBrainzGate = .shared,
                wikimediaSpacing: Duration = .seconds(1)) {
        self.fetcher = fetcher
        self.gate = gate
        wikimedia = RequestSpacer(spacing: wikimediaSpacing)
    }

    public func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistIdentityCandidate] {
        try ArtistInfoParsers.searchCandidates(try await musicBrainzData(Self.searchURL(name: name), lane: lane))
    }

    public func detail(musicBrainzID: String, lane: MusicBrainzGate.Lane) async throws
        -> (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String]) {
        try ArtistInfoParsers.artistDetail(try await musicBrainzData(Self.detailURL(musicBrainzID: musicBrainzID),
                                                                     lane: lane))
    }

    public func bio(wikidataID: String, preferredLanguages: [String]) async throws -> (extract: String, pageURL: URL)? {
        guard CommonsArtistParser.isEntityID(wikidataID),
              let entity = try await wikimediaData(Self.entityURL(wikidataID: wikidataID)),
              let choice = ArtistInfoParsers.wikipediaChoice(
                  sitelinks: try ArtistInfoParsers.wikipediaTitles(fromEntity: entity, id: wikidataID),
                  preferredLanguages: preferredLanguages),
              let url = Self.summaryURL(language: choice.language, title: choice.title),
              let summary = try await wikimediaData(url)
        else { return nil }
        return try ArtistInfoParsers.summary(summary)
    }

    // MARK: URLs

    /// `https://musicbrainz.org/ws/2/artist?query=artist:"<name>"&fmt=json&limit=10`.
    static func searchURL(name: String) -> URL {
        CommonsArtistSource.searchURL(name: name, limit: searchLimit)
    }

    /// The `+` stays as it is: MusicBrainz separates `inc` values with it.
    static func detailURL(musicBrainzID: String) -> URL {
        URL(string: "https://musicbrainz.org/ws/2/artist/\(ArtistPictureURLText.encoded(musicBrainzID))"
            + "?inc=url-rels+artist-rels+genres+release-groups&fmt=json")!
    }

    static func entityURL(wikidataID: String) -> URL {
        CommonsArtistSource.entityURL(id: wikidataID)
    }

    /// `https://<language>.wikipedia.org/api/rest_v1/page/summary/<title>`,
    /// the title with spaces as underscores (MediaWiki's own form) and the
    /// rest percent-encoded, `/` included. nil for a language code that is
    /// not plain letters, so it can only ever name a Wikipedia host.
    static func summaryURL(language: String, title: String) -> URL? {
        guard !language.isEmpty, language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let path = ArtistPictureURLText.encoded(title.replacingOccurrences(of: " ", with: "_"))
        return URL(string: "https://\(language.lowercased()).wikipedia.org/api/rest_v1/page/summary/\(path)")
    }

    // MARK: Private

    private func musicBrainzData(_ url: URL, lane: MusicBrainzGate.Lane) async throws -> Data {
        try await gate.wait(lane: lane)
        do {
            return try await fetcher.data(from: url)
        } catch ArtistPictureSourceError.http(503) {
            try await gate.wait(lane: lane)
            return try await fetcher.data(from: url)
        }
    }

    /// The body, or nil when the item or page does not exist (404).
    private func wikimediaData(_ url: URL) async throws -> Data? {
        try await wikimedia.wait()
        do {
            return try await fetcher.data(from: url)
        } catch ArtistPictureSourceError.http(404) {
            return nil
        }
    }
}
