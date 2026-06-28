import AppKit
import CryptoKit
import Foundation

public actor RemoteArtworkService {
    public enum FetchError: Error, LocalizedError {
        case missingQuery
        case noResults
        case networkFailure(URLError)
        case invalidImage

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
            }
        }
    }

    private static let userAgent = "CrateDigger/1.0 (https://smash.mrbarkan.com)"
    private static let preferredDimension = 1200

    private let session: URLSession
    private let cacheDirectory: URL?

    public init(session: URLSession? = nil) {
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

        guard let candidate = try await searchITunes(artist: trimmedArtist, album: trimmedAlbum) else {
            throw FetchError.noResults
        }

        let highRes = upgradeArtworkURL(candidate.artworkURL, to: Self.preferredDimension)
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

    private struct ITunesCandidate {
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

    private func scoreFor(_ candidate: ITunesCandidate, targetArtist: String, targetAlbum: String) -> Int {
        // Album match weighs twice as much as artist match.
        let albumScore = Self.distance(Self.simplify(candidate.album), targetAlbum) * 2
        let artistScore = Self.distance(Self.simplify(candidate.artist), targetArtist)
        return albumScore + artistScore
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

public struct MBReleaseCandidate: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let date: String?
    public let country: String?
    public let barcode: String?
    public let format: String?
    public let status: String?
    public let disambiguation: String?
    public let trackCount: Int?
    
    public init(id: String, title: String, date: String?, country: String?, barcode: String?, format: String?, status: String?, disambiguation: String?, trackCount: Int?) {
        self.id = id
        self.title = title
        self.date = date
        self.country = country
        self.barcode = barcode
        self.format = format
        self.status = status
        self.disambiguation = disambiguation
        self.trackCount = trackCount
    }
}

public struct CAABookletImage: Identifiable, Codable, Sendable {
    public var id: String { imageURL.absoluteString }
    public let imageURL: URL
    public let thumbnailURL: URL
    public let types: [String]
    public let comment: String
    public let front: Bool
    public let back: Bool
    
    public init(imageURL: URL, thumbnailURL: URL, types: [String], comment: String, front: Bool, back: Bool) {
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.types = types
        self.comment = comment
        self.front = front
        self.back = back
    }
}

public extension RemoteArtworkService {
    func searchMusicBrainzReleases(artist: String, album: String) async throws -> [MBReleaseCandidate] {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else {
            throw FetchError.missingQuery
        }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        var queryParts: [String] = []
        if !trimmedArtist.isEmpty {
            queryParts.append("artist:\"\(trimmedArtist)\"")
        }
        if !trimmedAlbum.isEmpty {
            queryParts.append("release:\"\(trimmedAlbum)\"")
        }
        let term = queryParts.joined(separator: " AND ")
        
        components.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "30")
        ]
        
        guard let url = components.url else { return [] }
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
            return []
        }

        struct MBSearchResponse: Decodable {
            let releases: [MBRelease]?
        }
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
            
            enum CodingKeys: String, CodingKey {
                case id, title, date, country, barcode, status, disambiguation
                case trackCount = "track-count"
                case media
            }
        }
        struct MBMedia: Decodable {
            let format: String?
        }

        let decoded = try JSONDecoder().decode(MBSearchResponse.self, from: data)
        guard let releases = decoded.releases else { return [] }

        return releases.map { rel in
            let format = rel.media?.first?.format
            return MBReleaseCandidate(
                id: rel.id,
                title: rel.title,
                date: rel.date,
                country: rel.country,
                barcode: rel.barcode,
                format: format,
                status: rel.status,
                disambiguation: rel.disambiguation == "" ? nil : rel.disambiguation,
                trackCount: rel.trackCount
            )
        }
    }

    func fetchCoverArtArchiveImages(releaseMBID: String) async throws -> [CAABookletImage] {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)") else {
            return []
        }
        
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
        
        guard let http = response as? HTTPURLResponse else {
            return []
        }
        
        if http.statusCode == 404 {
            return []
        }
        
        guard (200..<300).contains(http.statusCode) else {
            return []
        }
        
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
        
        let envelope = try JSONDecoder().decode(CAAEnvelope.self, from: data)
        return envelope.images.compactMap { img -> CAABookletImage? in
            guard let imageURL = URL(string: img.image) else { return nil }
            let thumbStr = img.thumbnails?.size250 ?? img.thumbnails?.size500 ?? img.thumbnails?.small ?? img.thumbnails?.large ?? img.image
            guard let thumbURL = URL(string: thumbStr) else { return nil }
            
            return CAABookletImage(
                imageURL: imageURL,
                thumbnailURL: thumbURL,
                types: img.types ?? [],
                comment: img.comment ?? "",
                front: img.front ?? false,
                back: img.back ?? false
            )
        }
    }
}

