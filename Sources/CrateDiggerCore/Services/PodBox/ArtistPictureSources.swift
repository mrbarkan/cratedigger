import Foundation

// MARK: - Fetching

/// The one way an artist-picture source reaches the network, so tests can
/// answer every request themselves and never touch it.
public protocol ArtistPictureFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum ArtistPictureSourceError: Error, Equatable, Sendable {
    /// The service said it has had enough for now (Deezer's error code 4).
    case quota
    /// The answer was not what the service documents: HTML, other JSON, an
    /// error object, a body far too large.
    case malformed
    /// A non-2xx status.
    case http(Int)
    /// The request never got an answer: offline, timed out, refused, cut off.
    case transport(String)
    /// A URL CrateDigger does not fetch from: not HTTPS, or not one of the
    /// sources' own hosts.
    case refusedURL

    /// Errors that say the service, or the network, is not answering now:
    /// asking again for the next artist would only fail the same way, so
    /// the run stops. Nothing learned from them may be stored as "not found".
    public var stopsTheRun: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return status == 0 || status == 429 || status >= 500
        case .quota, .malformed, .refusedURL: return false
        }
    }

    /// Any error, read as a source error: a `URLError` is a transport failure.
    static func reading(_ error: Error) -> ArtistPictureSourceError? {
        if let error = error as? ArtistPictureSourceError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? nil : .transport(error.localizedDescription)
        }
        return nil
    }
}

/// Plain HTTPS GETs that carry nothing about the person asking: an
/// ephemeral session (no cookies, no cache, no stored credentials), a 15 s
/// timeout, and the app's generic client name, the same for every install.
/// MusicBrainz and Wikimedia ask for a descriptive one, which is why it
/// names the app and its public site; it never holds a user name, an
/// e-mail, a path or a device name.
///
/// Only the sources' own hosts (and Wikipedia, for artist bios) are fetched
/// from, over HTTPS, redirects included, and a body is read as it arrives and
/// abandoned past 32 MB.
public struct URLSessionPictureFetcher: ArtistPictureFetching {
    public static let timeout: TimeInterval = 15
    /// The services the sources use, and the hosts their pictures come from.
    static let allowedHosts: Set<String> = [
        "api.deezer.com", "musicbrainz.org", "www.wikidata.org", "commons.wikimedia.org", "upload.wikimedia.org",
    ]
    /// Deezer's picture CDN (`e-cdns-images.dzcdn.net`, `cdn-images.dzcdn.net`),
    /// and every language's Wikipedia (`en.wikipedia.org`), for artist bios.
    static let allowedHostSuffixes = [".dzcdn.net", ".wikipedia.org"]

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ReleaseProviderSupport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    /// HTTPS to one of the allowed hosts, by name (never an address), on the default port.
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host) || allowedHostSuffixes.contains { host.hasSuffix($0) }
    }

    public func data(from url: URL) async throws -> Data {
        guard Self.isAllowed(url) else { throw ArtistPictureSourceError.refusedURL }
        let limit = ArtistPictureImage.maximumSourceBytes
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(for: url), delegate: RedirectGuard())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw ArtistPictureSourceError.http(status) }
            guard response.expectedContentLength <= Int64(limit) else { throw ArtistPictureSourceError.malformed }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw ArtistPictureSourceError.malformed }
            }
            return data
        } catch {
            throw ArtistPictureSourceError.reading(error) ?? error
        }
    }

    /// Follows a redirect only to another allowed host over HTTPS.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            URLSessionPictureFetcher.isAllowed(request.url) ? request : nil
        }
    }
}

/// Keeps one service's requests at least `spacing` apart (Deezer, Wikimedia;
/// for MusicBrainz see `MusicBrainzGate`). The slot is claimed before
/// sleeping: an actor is re-entrant across the sleep, so a gate that only
/// recorded the time afterwards would let every waiting caller fire at once.
public actor RequestSpacer {
    /// One request a second to Wikimedia (Wikidata, Wikipedia, Commons and
    /// its images) across every caller in the app: the artist info client,
    /// the lookup run and the Commons source share it.
    public static let wikimedia = RequestSpacer(spacing: .seconds(1))

    private let spacing: Duration
    private var next: ContinuousClock.Instant?

    public init(spacing: Duration) {
        self.spacing = spacing
    }

    func wait() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next ?? now)
        next = slot + spacing
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }
}

enum ArtistPictureURLText {
    /// Everything but RFC 3986's unreserved characters percent-encoded, so
    /// `&`, `+`, `/`, `=` and `?` in a name stay inside its one value.
    static func encoded(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

// MARK: - Candidates and sources

/// One picture a source offers for a name, with the albums it lists for
/// that artist (the cross-check of D2). `albumTitles` may be empty until
/// the source is asked for them.
public struct ArtistPictureCandidate: Hashable, Sendable {
    public let name: String, source: ArtistPictureSourceID, sourceID: String
    public let imageURL: URL
    public var albumTitles: [String]
    /// Who made the picture and under what licence, when the source says
    /// (Commons): kept with the stored record so the owner can be shown it.
    public var credit: ArtistPictureCredit?

    public init(name: String, source: ArtistPictureSourceID, sourceID: String, imageURL: URL,
                albumTitles: [String] = [], credit: ArtistPictureCredit? = nil) {
        self.name = name
        self.source = source
        self.sourceID = sourceID
        self.imageURL = imageURL
        self.albumTitles = albumTitles
        self.credit = credit
    }
}

public protocol ArtistPictureSource: Sendable {
    var id: ArtistPictureSourceID { get }
    /// What the service offers for `name`; each candidate's `albumTitles` may be empty.
    func candidates(for name: String) async throws -> [ArtistPictureCandidate]
    func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String]
    /// The same, with any MusicBrainz request waiting in `lane`: the
    /// background artist lookup passes `.background`, so a lookup the owner
    /// started never queues behind it. A source that never asks MusicBrainz
    /// need not implement these: they forward to the two above.
    func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistPictureCandidate]
    func albumTitles(for candidate: ArtistPictureCandidate, lane: MusicBrainzGate.Lane) async throws -> [String]
}

extension ArtistPictureSource {
    public func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistPictureCandidate] {
        try await candidates(for: name)
    }

    public func albumTitles(for candidate: ArtistPictureCandidate,
                            lane: MusicBrainzGate.Lane) async throws -> [String] {
        try await albumTitles(for: candidate)
    }
}

// MARK: - Deezer

/// Deezer's public API (no key): `search/artist` and `artist/<id>/albums`.
/// It answers some failures with a 200 and an `error` object, so every body
/// is checked for one before it is read.
public enum DeezerArtistParser {
    /// The `picture_xl` Deezer gives an artist with no picture: its hash is empty.
    static let placeholderMarker = "/images/artist//"
    static let quotaCode = 4
    /// Deezer's own picture CDN; a picture anywhere else is not taken.
    static let pictureHostSuffix = ".dzcdn.net"

    public static func artists(_ data: Data) throws -> [ArtistPictureCandidate] {
        try rows(data).compactMap { row in
            guard let name = text(row["name"]), let id = identifier(row["id"]),
                  let picture = text(row["picture_xl"]), !picture.contains(placeholderMarker),
                  let url = URL(string: picture), url.scheme == "https",
                  url.host?.lowercased().hasSuffix(pictureHostSuffix) == true,
                  URLSessionPictureFetcher.isAllowed(url)
            else { return nil }
            return ArtistPictureCandidate(name: name, source: .deezer, sourceID: id, imageURL: url)
        }
    }

    public static func albumTitles(_ data: Data) throws -> [String] {
        try rows(data).compactMap { text($0["title"]) }
    }

    /// `https://api.deezer.com/search/artist?q=artist:"<name>"&limit=10`. A
    /// double quote in the name would end Deezer's quoted term, so it is dropped.
    public static func searchURL(name: String) -> URL {
        let term = name.replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return URL(string: "https://api.deezer.com/search/artist?q=" + encoded("artist:\"\(term)\"") + "&limit=10")!
    }

    /// `https://api.deezer.com/artist/<id>/albums?limit=100`.
    public static func albumsURL(artistID: String) -> URL {
        URL(string: "https://api.deezer.com/artist/" + encoded(artistID) + "/albums?limit=100")!
    }

    // MARK: Private

    /// The `data` array of a Deezer answer, after ruling out an error body.
    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArtistPictureSourceError.malformed
        }
        if let error = object["error"] {
            let code = ((error as? [String: Any])?["code"] as? NSNumber)?.intValue
            throw code == quotaCode ? ArtistPictureSourceError.quota : ArtistPictureSourceError.malformed
        }
        guard let rows = object["data"] as? [Any] else { throw ArtistPictureSourceError.malformed }
        return rows.compactMap { $0 as? [String: Any] }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return text(value)
    }

    private static func encoded(_ text: String) -> String { ArtistPictureURLText.encoded(text) }
}

/// Deezer as a source: serial requests at least `spacing` apart. A quota
/// answer is thrown at once: the finder backs off for the whole run, outside
/// any one artist's time budget, rather than this source retrying inside it.
public struct DeezerArtistSource: ArtistPictureSource {
    public var id: ArtistPictureSourceID { .deezer }

    private let fetcher: ArtistPictureFetching
    private let spacer: RequestSpacer

    public init(fetcher: ArtistPictureFetching, spacing: Duration = .milliseconds(200)) {
        self.fetcher = fetcher
        spacer = RequestSpacer(spacing: spacing)
    }

    public func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
        try await read(DeezerArtistParser.searchURL(name: name), DeezerArtistParser.artists)
    }

    public func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] {
        try await read(DeezerArtistParser.albumsURL(artistID: candidate.sourceID), DeezerArtistParser.albumTitles)
    }

    private func read<T>(_ url: URL, _ parse: (Data) throws -> T) async throws -> T {
        try await spacer.wait()
        return try parse(try await fetcher.data(from: url))
    }
}

// MARK: - The owner's library

/// A picture the owner already keeps beside their music: `artist.jpg`,
/// `artist.png`, `folder.jpg` or `folder.png` (any case) in a library folder
/// whose name keys as the artist's and that holds only that artist's albums.
/// Read-only, on the Mac.
public enum LibraryFolderPictureSource {
    static let fileNames = ["artist.jpg", "artist.png", "folder.jpg", "folder.png"]

    /// `albumFolders` are the folders holding the artist's tracks. A disc
    /// folder (`CD1`) stands for the album above it. The folders looked at
    /// are the album's parent, then its grandparent, never an album folder
    /// itself: a `folder.jpg` there is the album's cover. `artistsByFolder`
    /// maps a folder to the folded names of the artists whose albums lie
    /// under it; a folder missing from it is not known to be single-artist.
    public static func picture(for name: String, albumFolders: [URL], artistsByFolder: [URL: Set<String>],
                               fileManager: FileManager = .default) -> URL? {
        let folded = PodBoxArtName.folded(name)
        guard !folded.isEmpty else { return nil }
        let owners = Dictionary(artistsByFolder.map { ($0.key.standardizedFileURL.path, $0.value) },
                                uniquingKeysWith: { $0.union($1) })
        let albums = Set(albumFolders.map { album -> String in
            let path = album.standardizedFileURL
            return PodBoxArtLookup.isDiscFolder(path.lastPathComponent)
                ? path.deletingLastPathComponent().path : path.path
        })
        let allAlbumPaths = albums.union(albumFolders.map(\.standardizedFileURL.path))

        var tried = Set<String>()
        for album in albums.sorted() {
            var folder = URL(fileURLWithPath: album, isDirectory: true)
            for _ in 0..<2 {
                folder = folder.deletingLastPathComponent()
                let path = folder.path
                guard path != "/", tried.insert(path).inserted, !allAlbumPaths.contains(path),
                      PodBoxArtName.matches(folder.lastPathComponent, name),
                      owners[path] == [folded],
                      let file = image(in: folder, fileManager)
                else { continue }
                return file
            }
        }
        return nil
    }

    private static func image(in folder: URL, _ fileManager: FileManager) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
        for wanted in fileNames {
            if let name = names.sorted().first(where: { $0.lowercased() == wanted }) {
                let url = folder.appendingPathComponent(name)
                var isFolder: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue { return url }
            }
        }
        return nil
    }
}
