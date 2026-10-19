import AppKit
import CryptoKit
import Foundation
import ImageIO

public actor RemoteArtworkService {
    public enum FetchError: Error, LocalizedError {
        case missingQuery
        case noResults
        case networkFailure(URLError)
        case invalidImage
        /// The server answered, but with an error rather than a result. Kept
        /// apart from "nothing found": a 502 from the archive is not a release
        /// with no scans, and a 503 from MusicBrainz is not a search with no
        /// matches.
        case serviceUnavailable(service: String, status: Int)

        public var errorDescription: String? {
            switch self {
            case .missingQuery:
                return "Need an artist or album name to search."
            case .noResults:
                return "No matching album cover was found online."
            case .networkFailure(let err):
                return "Network error: \(err.localizedDescription)"
            case .invalidImage:
                return "Couldn't read the image returned by the server."
            case .serviceUnavailable(let service, let status):
                return status == 503
                    ? "\(service) is busy right now. Try again in a moment."
                    : "\(service) didn't answer properly (error \(status)). Try again in a moment."
            }
        }
    }

    /// Versioned and with a contact URL, which is what MusicBrainz and Discogs
    /// both ask for. It used to say 1.0 whatever the build.
    private static var userAgent: String { ReleaseProviderSupport.userAgent }
    private static let preferredDimension = 1200
    /// Per-request ceiling for MusicBrainz search, which is far slower than the
    /// other endpoints this service talks to.
    static let musicBrainzTimeout: TimeInterval = 25

    private let session: URLSession
    private let cacheDirectory: URL?

    /// Release MBID → decoded Cover Art Archive image list. The release list
    /// probes counts per visible row while the user browses, and GET ARTWORK
    /// re-requests the same small JSON — cache it once per session so neither
    /// path refetches (404 "no images" results included).
    private var caaImagesByRelease: [String: [RemoteArtworkImage]] = [:]

    /// Release MBID → the Discogs release id MusicBrainz links it to (`nil`
    /// cached as "looked, found nothing"), and Discogs release id → its scans.
    /// Both are per-session: Discogs allows 25 requests a minute without a
    /// token, so re-opening the sheet must not spend any of them again.
    private var discogsIDByRelease: [String: String?] = [:]
    private var discogsImagesByRelease: [String: [RemoteArtworkImage]] = [:]
    /// Discogs search query → the release id it resolved to. Keyed by the query
    /// itself so the barcode and title rungs cache independently.
    private var discogsIDBySearch: [String: String?] = [:]

    /// Optional Discogs personal access token. Blank is fine — the public API
    /// serves release images unauthenticated, just at a lower rate limit.
    private var discogsToken: String?

    /// Image URL → true pixel size, from `probeDimensions`. Same reasoning as
    /// the list cache: reopening the sheet shouldn't re-probe every image.
    private var dimensionsByURL: [URL: ArtworkDimensions] = [:]
    /// Image URL → when its probe last failed. A row scrolling back into view
    /// asks again; this keeps a dead URL from being re-requested on every
    /// scroll, while still letting a later look succeed.
    private var dimensionFailures: [URL: Date] = [:]
    static let dimensionRetryInterval: TimeInterval = 60

    /// Release MBID → what MusicBrainz says the Cover Art Archive holds for it.
    /// Filled a release group at a time, so most searches cost one request.
    private var coverArtByRelease: [String: CoverArtSummary] = [:]
    /// Release groups already browsed in full, so a second search over the
    /// same album doesn't ask again.
    private var browsedReleaseGroups: Set<String> = []

    /// One Cover Art Archive index request per release at a time. GET ARTWORK
    /// pressed twice, or BACK and the same release again while the first is
    /// still on its way, used to send the slow archive the same request twice.
    private var caaInFlight: [String: Task<[RemoteArtworkImage], Error>] = [:]

    /// MusicBrainz asks for one request a second and answers 503 past it.
    /// Every MusicBrainz call this service makes (search, cover-art browse,
    /// the Discogs relation) waits for its slot here.
    private let musicBrainzInterval: TimeInterval
    private var nextMusicBrainzSlot = Date.distantPast

    /// Header probes go to archive.org through the Cover Art Archive's
    /// redirects. A full release used to fire one per image all at once, and a
    /// result list one per row; a handful at a time is as fast in practice and
    /// doesn't trip the archive's limits.
    static let maxConcurrentProbes = 4
    private var probesInFlight = 0
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []

    /// The pause before retrying a server error (MusicBrainz's 503, the
    /// archive's 502). Tests set it to zero.
    private let retryDelay: TimeInterval

    public init(session: URLSession? = nil, discogsToken: String? = nil,
                musicBrainzInterval: TimeInterval = 1.05, retryDelay: TimeInterval = 1.5) {
        self.musicBrainzInterval = musicBrainzInterval
        self.retryDelay = retryDelay
        self.discogsToken = discogsToken.flatMap { $0.isEmpty ? nil : $0 }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
        self.cacheDirectory = Self.makeCacheDirectory()
    }

    /// Settings can change the token while the app is running; the sheet pushes
    /// the current value in before a lookup rather than the actor caching a
    /// value read once at launch.
    public func setDiscogsToken(_ token: String?) {
        discogsToken = token.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func fetchArtwork(artist: String, album: String) async throws -> ArtworkAsset {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else {
            throw FetchError.missingQuery
        }

        let cacheKey = Self.cacheKey(artist: trimmedArtist, album: trimmedAlbum)
        if let cached = readCache(cacheKey: cacheKey),
           let asset = makeAsset(from: cached) {
            return asset
        }

        var found = try await searchITunes(artist: trimmedArtist, album: trimmedAlbum)
        if found == nil {
            // Loose retry: "OK Computer (Collector's Edition)" rarely matches
            // the store listing — the bare title usually does.
            let stripped = Self.strippedEditionTitle(trimmedAlbum)
            if stripped != trimmedAlbum, !stripped.isEmpty {
                found = try await searchITunes(artist: trimmedArtist, album: stripped)
            }
        }
        // iTunes misses plenty — small labels, non-US releases, a lot of
        // electronic and international catalogue. Deezer indexes those well and
        // its search is free, documented and keyless, so it is a cheap second
        // opinion before giving up. (The MusicBrainz + Cover Art Archive path
        // below is a separate, release-MBID-driven lookup.)
        var deezerCandidate: ITunesCandidate?
        if found == nil {
            deezerCandidate = try await searchDeezer(artist: trimmedArtist, album: trimmedAlbum)
            if deezerCandidate == nil {
                let stripped = Self.strippedEditionTitle(trimmedAlbum)
                if stripped != trimmedAlbum, !stripped.isEmpty {
                    deezerCandidate = try await searchDeezer(artist: trimmedArtist, album: stripped)
                }
            }
        }

        guard let candidate = found ?? deezerCandidate else {
            throw FetchError.noResults
        }

        // Deezer already hands back a full-size URL; only iTunes URLs carry the
        // resizable dimension token.
        let highRes = deezerCandidate == nil
            ? upgradeArtworkURL(candidate.artworkURL, to: Self.preferredDimension)
            : candidate.artworkURL
        let data = try await downloadImage(from: highRes)

        guard let asset = makeAsset(from: data) else {
            throw FetchError.invalidImage
        }

        writeCache(cacheKey: cacheKey, data: data)
        return asset
    }

    /// Disk-cache-only lookup. Returns nil without hitting the network.
    /// Callers can use this during scan to rehydrate art saved in a previous session.
    public func cachedArtwork(artist: String, album: String) -> ArtworkAsset? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else { return nil }
        let key = Self.cacheKey(artist: trimmedArtist, album: trimmedAlbum)
        guard let data = readCache(cacheKey: key) else { return nil }
        return makeAsset(from: data)
    }

    struct ITunesCandidate {
        let artist: String
        let album: String
        let artworkURL: URL
    }

    private func searchITunes(artist: String, album: String) async throws -> ITunesCandidate? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .returnCacheDataElseLoad

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw FetchError.networkFailure(urlError)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        struct Envelope: Decodable {
            let results: [Hit]
        }
        struct Hit: Decodable {
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }

        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        let candidates: [ITunesCandidate] = decoded.results.compactMap { hit in
            guard let artistName = hit.artistName,
                  let albumName = hit.collectionName,
                  let urlString = hit.artworkUrl100,
                  let url = URL(string: urlString) else { return nil }
            return ITunesCandidate(artist: artistName, album: albumName, artworkURL: url)
        }
        guard !candidates.isEmpty else { return nil }

        let targetArtist = Self.simplify(artist)
        let targetAlbum = Self.simplify(album)

        return candidates.min { lhs, rhs in
            scoreFor(lhs, targetArtist: targetArtist, targetAlbum: targetAlbum)
                < scoreFor(rhs, targetArtist: targetArtist, targetAlbum: targetAlbum)
        }
    }

    /// Deezer album search. Same shape as `searchITunes` and scored with the
    /// same distance function, so whichever provider answers, the best match is
    /// chosen on identical terms.
    private func searchDeezer(artist: String, album: String) async throws -> ITunesCandidate? {
        guard let url = Self.deezerSearchURL(artist: artist, album: album) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .returnCacheDataElseLoad

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw FetchError.networkFailure(urlError)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return Self.parseDeezer(data, artist: artist, album: album)
    }

    /// Deezer's advanced query syntax scopes the terms to the right fields —
    /// a bare term matches tracks and playlists too and drags in noise.
    static func deezerSearchURL(artist: String, album: String) -> URL? {
        var terms: [String] = []
        if !artist.isEmpty { terms.append("artist:\"\(Self.quoteEscaped(artist))\"") }
        if !album.isEmpty { terms.append("album:\"\(Self.quoteEscaped(album))\"") }
        guard !terms.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [
            URLQueryItem(name: "q", value: terms.joined(separator: " ")),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components.url
    }

    /// Deezer rejects unescaped quotes inside a quoted term.
    private static func quoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }

    static func parseDeezer(_ data: Data, artist: String, album: String) -> ITunesCandidate? {
        struct Envelope: Decodable { let data: [Hit]? }
        struct Hit: Decodable {
            struct Artist: Decodable { let name: String? }
            let title: String?
            let artist: Artist?
            /// 1000x1000 — Deezer's largest documented size.
            let coverXL: String?
            let coverBig: String?
            let cover: String?

            private enum CodingKeys: String, CodingKey {
                case title, artist
                case coverXL = "cover_xl"
                case coverBig = "cover_big"
                case cover
            }
        }

        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
              let hits = decoded.data, !hits.isEmpty else { return nil }

        let candidates: [ITunesCandidate] = hits.compactMap { hit in
            guard let title = hit.title,
                  let urlString = hit.coverXL ?? hit.coverBig ?? hit.cover,
                  !urlString.isEmpty,
                  let url = URL(string: urlString) else { return nil }
            return ITunesCandidate(artist: hit.artist?.name ?? "", album: title, artworkURL: url)
        }
        guard !candidates.isEmpty else { return nil }

        let targetArtist = Self.simplify(artist)
        let targetAlbum = Self.simplify(album)
        return candidates.min {
            Self.staticScore($0, targetArtist: targetArtist, targetAlbum: targetAlbum)
                < Self.staticScore($1, targetArtist: targetArtist, targetAlbum: targetAlbum)
        }
    }

    /// Same weighting as `scoreFor`, hoisted so parsing can be tested without a
    /// service instance.
    static func staticScore(_ candidate: ITunesCandidate, targetArtist: String, targetAlbum: String) -> Int {
        distance(simplify(candidate.album), targetAlbum) * 2
            + distance(simplify(candidate.artist), targetArtist)
    }

    private func scoreFor(_ candidate: ITunesCandidate, targetArtist: String, targetAlbum: String) -> Int {
        // Album match weighs twice as much as artist match.
        let albumScore = Self.distance(Self.simplify(candidate.album), targetAlbum) * 2
        let artistScore = Self.distance(Self.simplify(candidate.artist), targetArtist)
        return albumScore + artistScore
    }

    /// Fetch cover art from a URL we already know — a Cover Art Archive image
    /// for a release identified by disc ID, say, where there is nothing to
    /// search for. Follows the same download + decode path as a search hit.
    public func fetchArtwork(from url: URL) async throws -> ArtworkAsset {
        let data = try await downloadImage(from: url)
        guard let asset = makeAsset(from: data) else { throw FetchError.invalidImage }
        return asset
    }

    private func downloadImage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FetchError.invalidImage
            }
            return data
        } catch let urlError as URLError {
            throw FetchError.networkFailure(urlError)
        }
    }

    private func upgradeArtworkURL(_ url: URL, to dimension: Int) -> URL {
        // iTunes serves URLs like .../source/100x100bb.jpg.
        // Swap the dimension token for a larger one to get high-res art.
        let raw = url.absoluteString
        let target = "\(dimension)x\(dimension)bb"
        let upgraded = raw
            .replacingOccurrences(of: "100x100bb", with: target)
            .replacingOccurrences(of: "60x60bb", with: target)
            .replacingOccurrences(of: "30x30bb", with: target)
        return URL(string: upgraded) ?? url
    }

    private func makeAsset(from data: Data) -> ArtworkAsset? {
        guard let image = NSImage(data: data) else { return nil }
        return ArtworkAsset(
            source: .remote,
            hash: Self.sha256Hex(for: data),
            dimensions: ArtworkDimensions(
                width: Int(image.size.width.rounded()),
                height: Int(image.size.height.rounded())
            ),
            data: data
        )
    }

    private func readCache(cacheKey: String) -> Data? {
        guard let dir = cacheDirectory else { return nil }
        let url = dir.appendingPathComponent("\(cacheKey).jpg")
        return try? Data(contentsOf: url)
    }

    private func writeCache(cacheKey: String, data: Data) {
        guard let dir = cacheDirectory else { return }
        let url = dir.appendingPathComponent("\(cacheKey).jpg")
        try? data.write(to: url, options: .atomic)
    }

    private static func makeCacheDirectory() -> URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cache.appendingPathComponent("com.cratedigger.app/RemoteArtwork", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private static func cacheKey(artist: String, album: String) -> String {
        let raw = "\(simplify(artist))|\(simplify(album))"
        return String(sha256Hex(for: Data(raw.utf8)).prefix(40))
    }

    /// Drops parenthesized/bracketed edition decorations — "OK Computer
    /// (Collector's Edition) [2017 Remaster]" → "OK Computer" — for the loose
    /// retry when the exact title finds nothing.
    static func strippedEditionTitle(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            switch ch {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(ch) }
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static func simplify(_ s: String) -> String {
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return stripped.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var prev = Array(0...rhs.count)
        var curr = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            curr[0] = i
            for j in 1...rhs.count {
                let cost = (lhs[i - 1] == rhs[j - 1]) ? 0 : 1
                curr[j] = Swift.min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[rhs.count]
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

public struct MBReleaseCandidate: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let date: String?
    public let country: String?
    public let barcode: String?
    /// The first medium's format, which is what the MEDIA filter used to read.
    public let format: String?
    public let status: String?
    public let disambiguation: String?
    public let trackCount: Int?
    /// The credited artist as MusicBrainz prints it ("Simon & Garfunkel").
    public let artist: String?
    /// The release group this pressing belongs to. One browse of the group
    /// returns the Cover Art Archive count for every pressing in it.
    public let releaseGroupID: String?
    /// Every medium's format, in order: a 2-LP set is two "12\" Vinyl".
    public let formats: [String]

    public init(id: String, title: String, date: String?, country: String?, barcode: String?,
                format: String?, status: String?, disambiguation: String?, trackCount: Int?,
                artist: String? = nil, releaseGroupID: String? = nil, formats: [String]? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.country = country
        self.barcode = barcode
        self.format = format
        self.status = status
        self.disambiguation = disambiguation
        self.trackCount = trackCount
        self.artist = artist
        self.releaseGroupID = releaseGroupID
        self.formats = formats ?? (format.map { [$0] } ?? [])
    }

    /// Leading year of the release date ("1997-06-16" → 1997).
    public var year: Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// The media as a collector reads them: "CD", "2×12\" Vinyl", "CD + DVD".
    /// Nil when MusicBrainz lists no format at all.
    public var mediaSummary: String? {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for format in formats {
            if counts[format] == nil { order.append(format) }
            counts[format, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        return order.map { format in
            let n = counts[format] ?? 1
            return n > 1 ? "\(n)×\(format)" : format
        }.joined(separator: " + ")
    }
}

/// What MusicBrainz knows about a release's Cover Art Archive holding. It comes
/// from MusicBrainz's own database in the same response as the release, so
/// counting a whole result list costs one request per release group, not one
/// trip through archive.org per row.
public struct CoverArtSummary: Equatable, Sendable {
    public let count: Int
    public let hasFront: Bool
    public let hasBack: Bool
    /// Withdrawn at the rights holder's request: listed, but not served.
    public let darkened: Bool

    public init(count: Int, hasFront: Bool, hasBack: Bool, darkened: Bool = false) {
        self.count = count
        self.hasFront = hasFront
        self.hasBack = hasBack
        self.darkened = darkened
    }

    /// What GET ARTWORK will actually be able to show.
    public var available: Int { darkened ? 0 : count }
}

/// Where a candidate image came from. The Cover Art Archive types its images
/// (Front/Back/Booklet/Medium); Discogs only marks one primary and the rest
/// secondary, but carries far more scans of physical releases — sleeves,
/// labels, inserts, obi strips — which is why both are offered side by side.
public enum RemoteArtworkSource: String, Codable, Sendable {
    case coverArtArchive
    case discogs
    /// A file the user picked off their own disk. It rides in the same grid as
    /// the online candidates so both go through one review and one import.
    case localFile

    /// Badge text on the artwork grid, so it's obvious which database a scan
    /// came from before you commit it to the album folder.
    public var badge: String {
        switch self {
        case .coverArtArchive: return "CAA"
        case .discogs: return "DISCOGS"
        case .localFile: return "DISK"
        }
    }
}

public struct RemoteArtworkImage: Identifiable, Codable, Sendable {
    public var id: String { imageURL.absoluteString }
    public let imageURL: URL
    public let thumbnailURL: URL
    public let types: [String]
    public let comment: String
    public let front: Bool
    public let back: Bool
    public let source: RemoteArtworkSource
    /// A large derivative for the full-size preview, when the source offers
    /// one. Nil means the original is the preview (Discogs, local files).
    public let previewURL: URL?

    public init(imageURL: URL, thumbnailURL: URL, types: [String], comment: String,
                front: Bool, back: Bool, source: RemoteArtworkSource = .coverArtArchive,
                previewURL: URL? = nil) {
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.types = types
        self.comment = comment
        self.front = front
        self.back = back
        self.source = source
        self.previewURL = previewURL
    }

    /// What the preview overlay should load: never more than it can show.
    public var bestPreviewURL: URL { previewURL ?? imageURL }
}

public extension RemoteArtworkService {
    /// The query ladder for a MusicBrainz release search, strictest first:
    /// 1. exact quoted phrases, 2. quoted phrases with edition decorations
    /// stripped from the album, 3. unquoted bag-of-words (Lucene matches the
    /// tokens anywhere in the field). The service walks down the ladder until
    /// a rung returns results, so tagged titles that don't byte-match the
    /// MusicBrainz release name still find their release.
    static func musicBrainzQueryAttempts(artist: String, album: String) -> [String] {
        func query(_ artistPart: String, _ albumPart: String, quoted: Bool) -> String {
            var parts: [String] = []
            if !artistPart.isEmpty {
                parts.append(quoted ? "artist:\"\(artistPart)\"" : "artist:(\(artistPart))")
            }
            if !albumPart.isEmpty {
                parts.append(quoted ? "release:\"\(albumPart)\"" : "release:(\(albumPart))")
            }
            return parts.joined(separator: " AND ")
        }

        var attempts = [query(artist, album, quoted: true)]
        let stripped = strippedEditionTitle(album)
        if stripped != album, !stripped.isEmpty {
            attempts.append(query(artist, stripped, quoted: true))
        }
        let loose = query(artist, stripped.isEmpty ? album : stripped, quoted: false)
        if !attempts.contains(loose) {
            attempts.append(loose)
        }
        return attempts
    }

    func searchMusicBrainzReleases(artist: String, album: String) async throws -> [MBReleaseCandidate] {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else {
            throw FetchError.missingQuery
        }

        // One rung failing must not end the search. The strict quoted query is
        // the one most likely to return nothing, so the looser rungs below it
        // are exactly the ones a user with an oddly-tagged album depends on —
        // and a timeout on the first attempt used to throw all of them away.
        // Only a search where every rung failed is a failed search.
        var lastFailure: Error?
        for term in Self.musicBrainzQueryAttempts(artist: trimmedArtist, album: trimmedAlbum) {
            do {
                let releases = try await performMusicBrainzQuery(term)
                if !releases.isEmpty { return releases }
            } catch FetchError.serviceUnavailable(let service, 503) {
                // Busy is busy for every rung: asking a looser query only
                // spends more of the rate limit before saying so.
                throw FetchError.serviceUnavailable(service: service, status: 503)
            } catch {
                lastFailure = error
            }
        }
        if let lastFailure { throw lastFailure }
        return []
    }

    private func performMusicBrainzQuery(_ term: String) async throws -> [MBReleaseCandidate] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "30")
        ]
        guard let url = components.url else { return [] }

        // MusicBrainz's search server is genuinely slow: a plain artist+album
        // query measured over 5s on a good connection, and it goes well past
        // the session's 12s default under load. A cover search is worth waiting
        // for; timing it out at 12s reported "the request timed out" for a
        // query that was simply still running.
        let data: Data
        do {
            data = try await musicBrainzData(from: url, cachePolicy: .returnCacheDataElseLoad)
        } catch FetchError.serviceUnavailable(_, let status) where status == 400 {
            // A query MusicBrainz can't parse (stray Lucene syntax in a tag)
            // finds nothing; the next rung may still find something.
            return []
        }

        struct MBSearchResponse: Decodable {
            let releases: [MBRelease]?
        }
        let decoded = try JSONDecoder().decode(MBSearchResponse.self, from: data)
        return (decoded.releases ?? []).map(\.candidate)
    }

    // MARK: MusicBrainz plumbing

    /// Waits for this request's turn. The slot is claimed *before* sleeping:
    /// an actor is re-entrant across the sleep, so a throttle that only
    /// records the time afterwards lets every caller that arrived during the
    /// wait read the same old timestamp and fire together.
    private func waitForMusicBrainzSlot() async throws {
        let now = Date()
        let slot = max(now, nextMusicBrainzSlot)
        nextMusicBrainzSlot = slot.addingTimeInterval(musicBrainzInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// One MusicBrainz GET: throttled, identified, and honest about failure.
    /// A 503 is MusicBrainz's rate limiter or a busy server, which on
    /// 2026-10-12 came and went in bursts of several seconds, so it gets two
    /// retries with a growing pause; any other non-2xx answer throws rather
    /// than passing for an empty result.
    func musicBrainzData(from url: URL,
                         cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        var lastStatus = 0
        for attempt in 0..<3 {
            try await waitForMusicBrainzSlot()
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.cachePolicy = cachePolicy
            request.timeoutInterval = Self.musicBrainzTimeout

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                throw FetchError.networkFailure(urlError)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            lastStatus = status
            guard status == 503, attempt < 2 else { break }
            let pause = retryDelay * Double(attempt + 1)
            nextMusicBrainzSlot = max(nextMusicBrainzSlot, Date().addingTimeInterval(pause))
        }
        throw FetchError.serviceUnavailable(service: "MusicBrainz", status: lastStatus)
    }

    // MARK: Cover Art Archive counts

    /// The Cover Art Archive holding for each of `releases`, delivered a batch
    /// at a time as MusicBrainz answers: one browse per release group (in the
    /// order the groups first appear, so the top of the list fills first),
    /// then one lookup for any release the browse didn't cover. A value of
    /// `nil` means "couldn't be counted", never "has no images".
    ///
    /// This replaced reading each release's full image index off archive.org
    /// just to count it. That index lives behind a redirect to archive.org,
    /// which on 2026-10-12 answered 502 or timed out for most of a 12-row
    /// list, and every failure read as "NO IMAGES" or as nothing at all.
    nonisolated func coverArtSummaries(
        for releases: [MBReleaseCandidate]
    ) -> AsyncStream<[String: CoverArtSummary?]> {
        AsyncStream { continuation in
            let task = Task {
                for batch in CoverArtCountPlan.batches(for: releases) {
                    if Task.isCancelled { break }
                    continuation.yield(await self.summaries(for: batch))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func summaries(for batch: CoverArtCountPlan.Batch) async -> [String: CoverArtSummary?] {
        var result: [String: CoverArtSummary?] = [:]
        switch batch {
        case let .releaseGroup(groupID, releaseIDs):
            let found = try? await coverArtSummaries(releaseGroupID: groupID, wanting: Set(releaseIDs))
            for id in releaseIDs { result[id] = found?[id] }
        case let .release(id):
            result[id] = try? await coverArtSummary(releaseMBID: id)
        }
        return result
    }

    /// Browse every pressing in a release group, a hundred at a time, until
    /// the ones asked for have all turned up. Each page costs a MusicBrainz
    /// second, so a group with hundreds of pressings stops at three pages.
    func coverArtSummaries(releaseGroupID: String,
                           wanting wanted: Set<String>) async throws -> [String: CoverArtSummary] {
        var missing = wanted.filter { coverArtByRelease[$0] == nil }
        if !missing.isEmpty, !browsedReleaseGroups.contains(releaseGroupID) {
            var offset = 0
            for _ in 0..<Self.maxBrowsePages {
                var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
                components.queryItems = [
                    URLQueryItem(name: "release-group", value: releaseGroupID),
                    URLQueryItem(name: "fmt", value: "json"),
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "offset", value: String(offset))
                ]
                guard let url = components.url else { break }
                let page = Self.parseCoverArtBrowse(try await musicBrainzData(from: url))
                coverArtByRelease.merge(page.summaries) { _, new in new }
                missing.subtract(page.summaries.keys)
                offset += page.returned
                if page.returned == 0 || offset >= page.total {
                    browsedReleaseGroups.insert(releaseGroupID)
                    break
                }
                if missing.isEmpty { break }
            }
        }
        var found: [String: CoverArtSummary] = [:]
        for id in wanted { if let summary = coverArtByRelease[id] { found[id] = summary } }
        return found
    }

    static let maxBrowsePages = 3

    /// One release's holding, for a search hit with no release group.
    func coverArtSummary(releaseMBID: String) async throws -> CoverArtSummary? {
        if let cached = coverArtByRelease[releaseMBID] { return cached }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/\(releaseMBID)?fmt=json") else { return nil }
        let data = try await musicBrainzData(from: url)
        let summary = (try? JSONDecoder().decode(MBRelease.self, from: data))?.coverArt?.summary
        if let summary { coverArtByRelease[releaseMBID] = summary }
        return summary
    }

    /// A MusicBrainz release browse, reduced to each release's Cover Art
    /// Archive holding, how many releases this page carried and how many the
    /// browse has in all.
    static func parseCoverArtBrowse(_ data: Data) -> (summaries: [String: CoverArtSummary], returned: Int, total: Int) {
        struct Browse: Decodable {
            let releases: [MBRelease]?
            let releaseCount: Int?
            enum CodingKeys: String, CodingKey {
                case releases
                case releaseCount = "release-count"
            }
        }
        guard let browse = try? JSONDecoder().decode(Browse.self, from: data) else { return ([:], 0, 0) }
        let releases = browse.releases ?? []
        var summaries: [String: CoverArtSummary] = [:]
        for release in releases {
            if let summary = release.coverArt?.summary { summaries[release.id] = summary }
        }
        return (summaries, releases.count, browse.releaseCount ?? releases.count)
    }

    // MARK: Cover Art Archive images

    func fetchCoverArtArchiveImages(releaseMBID: String) async throws -> [RemoteArtworkImage] {
        if let cached = caaImagesByRelease[releaseMBID] {
            return cached
        }
        if let running = caaInFlight[releaseMBID] {
            return try await running.value
        }
        let task = Task { try await self.loadCoverArtArchiveImages(releaseMBID: releaseMBID) }
        caaInFlight[releaseMBID] = task
        defer { caaInFlight[releaseMBID] = nil }
        let images = try await task.value
        caaImagesByRelease[releaseMBID] = images
        return images
    }

    /// The archive's index for one release. It is served from archive.org
    /// behind a redirect, and archive.org is slow (10 to 20 seconds when it
    /// answers at all) and often answers 502 at once, so a fast server error
    /// gets one retry, and any error that survives it throws: only a 404 means
    /// the release has no images.
    private func loadCoverArtArchiveImages(releaseMBID: String) async throws -> [RemoteArtworkImage] {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)") else {
            return []
        }
        var lastStatus = 0
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = Self.musicBrainzTimeout

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                throw FetchError.networkFailure(urlError)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return [] }
            if (200..<300).contains(status) { return try Self.parseCoverArtArchiveIndex(data) }
            lastStatus = status
            guard (500..<600).contains(status), attempt == 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        throw FetchError.serviceUnavailable(service: "The Cover Art Archive", status: lastStatus)
    }

    static func parseCoverArtArchiveIndex(_ data: Data) throws -> [RemoteArtworkImage] {
        struct CAAEnvelope: Decodable {
            let images: [CAAImage]
        }
        struct CAAImage: Decodable {
            let image: String
            let thumbnails: CAAThumbnails?
            let types: [String]?
            let comment: String?
            let front: Bool?
            let back: Bool?
        }
        struct CAAThumbnails: Decodable {
            let large: String?
            let small: String?
            let size250: String?
            let size500: String?
            let size1200: String?

            enum CodingKeys: String, CodingKey {
                case large, small
                case size250 = "250"
                case size500 = "500"
                case size1200 = "1200"
            }
        }

        // Cover Art Archive hands back `http://` URLs; App Transport Security
        // blocks those, so the images would spin forever. Rewrite to https.
        func https(_ string: String?) -> URL? {
            guard let string else { return nil }
            return URL(string: string.hasPrefix("http://") ? "https://" + string.dropFirst(7) : string)
        }

        let envelope = try JSONDecoder().decode(CAAEnvelope.self, from: data)
        return envelope.images.compactMap { img -> RemoteArtworkImage? in
            guard let imageURL = https(img.image) else { return nil }
            let thumbs = img.thumbnails
            guard let thumbURL = https(thumbs?.size250 ?? thumbs?.small ?? thumbs?.size500 ?? thumbs?.large ?? img.image)
            else { return nil }
            // The full-size preview fills at most ~560pt; a 1200px derivative
            // is sharp at that size on a Retina screen and a fraction of an
            // original that can run to 5000px and several megabytes.
            let previewURL = https(thumbs?.size1200 ?? thumbs?.large ?? thumbs?.size500)

            return RemoteArtworkImage(
                imageURL: imageURL,
                thumbnailURL: thumbURL,
                types: img.types ?? [],
                comment: img.comment ?? "",
                front: img.front ?? false,
                back: img.back ?? false,
                previewURL: previewURL
            )
        }
    }

    // MARK: Header probes

    /// The front cover's true pixel size, read off the archive's `/front`
    /// redirect. Ask only for a release MusicBrainz says has a front.
    func frontCoverDimensions(releaseMBID: String) async -> ArtworkDimensions? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front") else { return nil }
        return await probeDimensions(of: url)
    }

    /// True pixel size of a remote image, read from its header alone.
    ///
    /// Cover Art Archive lists a "1200" thumbnail tier for every image it has
    /// re-derived, *including* ones whose original is 600px, so the JSON can't
    /// be used as a resolution hint. Range-request the first 64 KB instead and
    /// let ImageIO parse the JPEG SOF / PNG IHDR marker, which lives up front.
    /// Returns nil if the server ignores the range or the header doesn't parse;
    /// callers just show no size rather than a wrong one.
    ///
    /// At most `maxConcurrentProbes` run at once. A failure is remembered for
    /// a minute so a row scrolling in and out doesn't ask again each time; a
    /// probe that was cancelled (the row scrolled away) is not a failure.
    func probeDimensions(of url: URL) async -> ArtworkDimensions? {
        if let cached = dimensionsByURL[url] { return cached }
        if let failedAt = dimensionFailures[url],
           Date().timeIntervalSince(failedAt) < Self.dimensionRetryInterval { return nil }

        await acquireProbeSlot()
        defer { releaseProbeSlot() }
        if let cached = dimensionsByURL[url] { return cached }   // landed while queued
        guard !Task.isCancelled else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let result = try? await session.data(for: request)
        if Task.isCancelled { return nil }
        guard let (data, _) = result, !data.isEmpty,
              let dimensions = Self.dimensions(ofImageHeader: data) else {
            dimensionFailures[url] = Date()
            return nil
        }
        dimensionsByURL[url] = dimensions
        dimensionFailures[url] = nil
        return dimensions
    }

    private static func dimensions(ofImageHeader data: Data) -> ArtworkDimensions? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return ArtworkDimensions(width: width, height: height)
    }

    private func acquireProbeSlot() async {
        if probesInFlight < Self.maxConcurrentProbes {
            probesInFlight += 1
            return
        }
        await withCheckedContinuation { probeWaiters.append($0) }
    }

    /// Hands the slot straight to the next waiter rather than freeing it, so a
    /// newcomer can't overtake the queue.
    private func releaseProbeSlot() {
        if probeWaiters.isEmpty {
            probesInFlight -= 1
        } else {
            probeWaiters.removeFirst().resume()
        }
    }
}

/// The order in which a result list's Cover Art Archive counts are asked for.
public enum CoverArtCountPlan {
    public enum Batch: Equatable, Sendable {
        /// One browse answers for every listed pressing in the group.
        case releaseGroup(id: String, releaseIDs: [String])
        /// A release with no group to browse: one lookup.
        case release(id: String)
    }

    /// Groups in the order they first appear in `releases`, so the rows at the
    /// top of the list are counted first; ungrouped releases after them.
    public static func batches(for releases: [MBReleaseCandidate]) -> [Batch] {
        var groupOrder: [String] = []
        var members: [String: [String]] = [:]
        var loose: [String] = []
        for release in releases {
            guard let group = release.releaseGroupID, !group.isEmpty else {
                if !loose.contains(release.id) { loose.append(release.id) }
                continue
            }
            if members[group] == nil { groupOrder.append(group) }
            if members[group]?.contains(release.id) != true { members[group, default: []].append(release.id) }
        }
        return groupOrder.map { .releaseGroup(id: $0, releaseIDs: members[$0] ?? []) }
            + loose.map { .release(id: $0) }
    }
}

/// The parts of a MusicBrainz release this service reads, shared by search,
/// browse and lookup responses.
struct MBRelease: Decodable {
    let id: String
    let title: String
    let date: String?
    let country: String?
    let barcode: String?
    let status: String?
    let disambiguation: String?
    let trackCount: Int?
    let media: [MBMedia]?
    let artistCredit: [MBArtistCredit]?
    let releaseGroup: MBReleaseGroupRef?
    let coverArt: MBCoverArt?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, barcode, status, disambiguation, media
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
        case coverArt = "cover-art-archive"
    }

    var candidate: MBReleaseCandidate {
        let formats = (media ?? []).compactMap(\.format)
        let credit = artistCredit.map(MBArtistCredit.joined) ?? ""
        return MBReleaseCandidate(
            id: id,
            title: title,
            date: date,
            country: country,
            barcode: barcode == "" ? nil : barcode,
            format: formats.first,
            status: status,
            disambiguation: disambiguation == "" ? nil : disambiguation,
            trackCount: trackCount,
            artist: credit.isEmpty ? nil : credit,
            releaseGroupID: releaseGroup?.id,
            formats: formats
        )
    }
}

struct MBMedia: Decodable {
    let format: String?
}

struct MBReleaseGroupRef: Decodable {
    let id: String?
}

struct MBArtistCredit: Decodable {
    let name: String?
    let joinphrase: String?

    /// "Simon" + " & " + "Garfunkel", the way the sleeve prints it.
    static func joined(_ credits: [MBArtistCredit]) -> String {
        credits.map { ($0.name ?? "") + ($0.joinphrase ?? "") }.joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

struct MBCoverArt: Decodable {
    let count: Int?
    let front: Bool?
    let back: Bool?
    let darkened: Bool?

    var summary: CoverArtSummary {
        CoverArtSummary(count: count ?? 0, hasFront: front ?? false,
                        hasBack: back ?? false, darkened: darkened ?? false)
    }
}

// MARK: - Discogs

/// Discogs holds the deepest catalogue of *physical* release scans — back
/// sleeves, spines, labels, inners, inserts, obi strips — where the Cover Art
/// Archive is mostly fronts. Reaching it costs nothing extra to search: a
/// MusicBrainz release already carries a `discogs` URL relation, and the
/// artwork sheet has resolved that release MBID by the time it asks for images.
///
/// Unauthenticated works today (25 requests a minute); a personal access token
/// raises that to 60 and insures against Discogs re-gating image URLs, which it
/// has done before. Either way Discogs requires a descriptive User-Agent.
public extension RemoteArtworkService {

    /// Find this release on Discogs, cheapest and most certain first:
    ///
    /// 1. the `discogs` relation MusicBrainz stores for the release — exact, and
    ///    free, because it rides along with a lookup already being made;
    /// 2. its barcode — the same number is printed on the same physical object,
    ///    so a hit is the same pressing;
    /// 3. artist + title, with the title checked against the result, for the
    ///    releases MusicBrainz has neither linked nor barcoded.
    ///
    /// Rung 1 covers pressings well (4 of 4 sampled pressings of one album were
    /// linked) but misses digital-era releases entirely, which is what 2 and 3
    /// are for. Each rung costs one request only when the one above it missed.
    func discogsImages(for release: MBReleaseCandidate, artist: String) async -> [RemoteArtworkImage] {
        let year = release.date.flatMap { Int($0.prefix(4)) }

        var releaseID = await discogsReleaseID(forReleaseMBID: release.id)
        if releaseID == nil, let barcode = release.barcode?.trimmingCharacters(in: .whitespaces), !barcode.isEmpty {
            releaseID = await searchDiscogs(
                parameters: [URLQueryItem(name: "barcode", value: barcode)],
                preferredYear: year,
                expectedTitle: nil   // a barcode already identifies the object
            )
        }
        if releaseID == nil, !release.title.isEmpty {
            releaseID = await searchDiscogs(
                parameters: [
                    URLQueryItem(name: "artist", value: artist),
                    URLQueryItem(name: "release_title", value: release.title)
                ],
                preferredYear: year,
                expectedTitle: release.title
            )
        }
        guard let releaseID else { return [] }
        return await discogsImages(releaseID: releaseID)
    }

    /// One Discogs search, cached by its query. Returns the id of the best
    /// matching release, or none.
    func searchDiscogs(parameters: [URLQueryItem], preferredYear: Int?, expectedTitle: String?) async -> String? {
        var components = URLComponents(string: "https://api.discogs.com/database/search")!
        components.queryItems = parameters + [URLQueryItem(name: "type", value: "release")]
        guard let url = components.url else { return nil }
        let cacheKey = url.absoluteString
        if let cached = discogsIDBySearch[cacheKey] { return cached }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let discogsToken {
            request.setValue("Discogs token=\(discogsToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil   // not cached: rate-limited or offline deserves a retry
        }

        let found = Self.pickDiscogsSearchHit(data, preferredYear: preferredYear, expectedTitle: expectedTitle)
        discogsIDBySearch[cacheKey] = found
        return found
    }

    /// The scans on one Discogs release.
    func discogsImages(releaseID: String) async -> [RemoteArtworkImage] {
        if let cached = discogsImagesByRelease[releaseID] { return cached }
        guard let url = URL(string: "https://api.discogs.com/releases/\(releaseID)") else { return [] }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let discogsToken {
            request.setValue("Discogs token=\(discogsToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return []   // rate-limited, offline, or a release that has gone away
        }

        let images = Self.parseDiscogsImages(data)
        discogsImagesByRelease[releaseID] = images
        return images
    }

    /// The Discogs release id MusicBrainz links this release to. Cached
    /// including the misses: a release with no Discogs link must not re-ask
    /// MusicBrainz every time the sheet opens.
    func discogsReleaseID(forReleaseMBID mbid: String) async -> String? {
        if let cached = discogsIDByRelease[mbid] { return cached }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/\(mbid)?inc=url-rels&fmt=json"),
              let data = try? await musicBrainzData(from: url)
        else {
            return nil   // not cached: a network blip should be retried, unlike a real "no link"
        }

        let found = Self.parseDiscogsReleaseID(data)
        discogsIDByRelease[mbid] = found
        return found
    }
}

public extension RemoteArtworkService {

    /// Pull the Discogs release id out of a MusicBrainz release's url-relations.
    /// Only `/release/<id>` counts — a relation to a Discogs *master* addresses
    /// a group of pressings, whose images are not this release's.
    static func parseDiscogsReleaseID(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Relation: Decodable {
                struct Target: Decodable { let resource: String? }
                let type: String?
                let url: Target?
            }
            let relations: [Relation]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        for relation in decoded.relations ?? [] where relation.type?.lowercased() == "discogs" {
            guard let resource = relation.url?.resource,
                  let range = resource.range(of: "/release/")
            else { continue }
            let trailing = resource[range.upperBound...].prefix { $0.isNumber }
            if !trailing.isEmpty { return String(trailing) }
        }
        return nil
    }

    /// Choose the best release from a Discogs search.
    ///
    /// `expectedTitle` guards the loose artist+title rung: Discogs formats its
    /// result titles as "Artist - Title", so the album must actually appear in
    /// there before its scans are written into someone's album folder. The
    /// barcode rung passes `nil` — the number already identifies the object.
    ///
    /// Among acceptable hits the release year wins, since a reissue's sleeve
    /// often isn't the one on the shelf; failing that the first hit stands,
    /// Discogs already having ranked them.
    static func pickDiscogsSearchHit(_ data: Data, preferredYear: Int?, expectedTitle: String?) -> String? {
        struct Response: Decodable {
            struct Hit: Decodable {
                let id: Int?
                let title: String?
                let year: String?
            }
            let results: [Hit]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        let wanted = expectedTitle.map(simplify)
        let acceptable = (decoded.results ?? []).filter { hit in
            guard hit.id != nil else { return false }
            guard let wanted, !wanted.isEmpty else { return true }
            return simplify(hit.title ?? "").contains(wanted)
        }
        guard !acceptable.isEmpty else { return nil }

        if let preferredYear,
           let sameYear = acceptable.first(where: { Int($0.year ?? "") == preferredYear }) {
            return sameYear.id.map(String.init)
        }
        return acceptable.first?.id.map(String.init)
    }

    /// Map a Discogs release payload onto artwork candidates.
    ///
    /// Discogs marks exactly one image `primary` and everything else
    /// `secondary` — it doesn't say which secondary is the back and which is a
    /// label. So only the front is claimed here; the rest arrive unroled and
    /// the sheet's role picker (which the user drives anyway) assigns them.
    static func parseDiscogsImages(_ data: Data) -> [RemoteArtworkImage] {
        struct Response: Decodable {
            struct Image: Decodable {
                let type: String?
                let uri: String?
                let uri150: String?
            }
            let images: [Image]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (decoded.images ?? []).compactMap { image in
            guard let uri = image.uri, let full = URL(string: uri) else { return nil }
            let isPrimary = image.type?.lowercased() == "primary"
            return RemoteArtworkImage(
                imageURL: full,
                thumbnailURL: image.uri150.flatMap { URL(string: $0) } ?? full,
                types: isPrimary ? ["Front"] : [],
                comment: "",
                front: isPrimary,
                back: false,
                source: .discogs
            )
        }
    }
}
