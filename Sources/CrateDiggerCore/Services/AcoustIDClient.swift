import Foundation

/// A MusicBrainz recording that AcoustID says a fingerprint is, plus the
/// releases that recording appears on.
public struct AcoustIDRecording: Equatable, Sendable {
    /// MusicBrainz recording MBID.
    public let id: String
    /// MusicBrainz release MBIDs this recording appears on.
    public let releaseIDs: [String]

    public init(id: String, releaseIDs: [String]) {
        self.id = id
        self.releaseIDs = releaseIDs
    }
}

/// AcoustID refused the request itself, as opposed to simply not recognising
/// the audio. The two look identical to a user unless we say which happened,
/// and one of them is a configuration mistake nobody can debug from "no match".
public enum AcoustIDError: Error, Equatable, LocalizedError {
    case service(code: Int, message: String)

    /// AcoustID's error code 4. Almost always the account API key from
    /// acoustid.org/api-key being used where an application key belongs.
    public var isInvalidKey: Bool {
        if case .service(let code, _) = self { return code == 4 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .service(let code, let message):
            return "AcoustID refused the lookup (\(code)): \(message)"
        }
    }
}

/// AcoustID: looks a Chromaprint fingerprint up and answers with the
/// MusicBrainz recordings that audio is.
///
/// Free and keyed per *application*, not per user, which is why the key is a
/// constant here rather than a preference — it identifies CrateDigger, it is
/// not a credential for anybody's data. The published rate limit is three
/// requests a second, enforced by the actor's throttle.
///
/// One request per file. AcoustID does document a batched form, but a single
/// fingerprint per request is the shape every client uses and the one whose
/// response is unambiguous; an album costs four seconds of throttle, which is
/// nothing next to the decode that produced the fingerprints.
public actor AcoustIDClient {

    /// Set this to the key CrateDigger's **application** registration was
    /// issued, from acoustid.org/new-application (listed afterwards under
    /// acoustid.org/my-applications).
    ///
    /// It is NOT the account API key on acoustid.org/api-key. That one signs
    /// fingerprint *submissions*; lookups authenticate as an application. The
    /// two look alike (ten mixed-case characters), which is exactly why this
    /// comment exists: sending the account key returns error code 4, "invalid
    /// API key", and nothing else about the request is wrong.
    public static let applicationKey = "nXeadWe0ud"

    /// Stands in when the application key hasn't been set. Checked before a
    /// deep scan spends a minute decoding audio for a request that cannot
    /// succeed.
    public static let placeholderKey = "REPLACE_WITH_ACOUSTID_APPLICATION_KEY"

    private static let endpoint = URL(string: "https://api.acoustid.org/v2/lookup")!
    /// AcoustID allows three requests a second.
    private static let minimumRequestInterval: TimeInterval = 0.35
    /// Below this AcoustID is guessing, and a guess that reaches the vote is
    /// worse than a file that abstains.
    static let minimumResultScore = 0.5

    private let session: URLSession
    private let apiKey: String
    private var lastRequestAt: Date?

    public init(session: URLSession? = nil, apiKey: String = applicationKey) {
        self.session = session ?? ReleaseProviderSupport.makeSession()
        self.apiKey = apiKey
    }

    /// The recordings AcoustID believes this fingerprint is, best result first.
    /// An unrecognised fingerprint is an empty array, not an error.
    public func recordings(for fingerprint: AudioFingerprint) async throws -> [AcoustIDRecording] {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumRequestInterval {
                try await Task.sleep(nanoseconds: UInt64((Self.minimumRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(ReleaseProviderSupport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(apiKey: apiKey, fingerprint: fingerprint).utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // AcoustID explains itself in the body of a 400. Throwing the status
            // alone would turn "your key is wrong" into "the lookup failed".
            if let serviceError = Self.serviceError(in: data) { throw serviceError }
            throw ReleaseLookupError.badStatus(http.statusCode)
        }
        if let serviceError = Self.serviceError(in: data) { throw serviceError }
        return try Self.parse(data)
    }

    /// The form body for one lookup. Fingerprints run to thousands of
    /// characters, which is why this is a POST and not a query string.
    static func formBody(apiKey: String, fingerprint: AudioFingerprint) -> String {
        [
            "client=\(escape(apiKey))",
            "duration=\(fingerprint.durationSeconds)",
            "fingerprint=\(escape(fingerprint.fingerprint))",
            // Recordings tell us *what* the audio is; release IDs tell us which
            // pressings it appears on, which is what the vote runs over.
            //
            // The "+" is deliberately unescaped: AcoustID separates meta values
            // with a space, and a form body decodes "+" to one. Percent-encode
            // it to %2B and the whole parameter is silently ignored — results
            // come back with scores and nothing else, which looks like an
            // unknown recording rather than a malformed request.
            "meta=recordings+releaseids"
        ].joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        // Chromaprint strings are base64url and contain "-" and "_", which are
        // safe, but the key and any future field may not be.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// AcoustID's error envelope, when the response carries one.
    static func serviceError(in data: Data) -> AcoustIDError? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              envelope.status == "error",
              let error = envelope.error
        else { return nil }
        return .service(code: error.code ?? 0, message: error.message ?? "no reason given")
    }

    /// The recordings from the best-scoring result. Results below
    /// `minimumResultScore` are dropped rather than allowed to vote.
    static func parse(_ data: Data) throws -> [AcoustIDRecording] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let best = (response.results ?? [])
            .filter({ ($0.score ?? 0) >= minimumResultScore })
            .max(by: { ($0.score ?? 0) < ($1.score ?? 0) })
        else { return [] }

        // `meta=recordings+releaseids` nests releases under each recording. A
        // response carrying only top-level releases (no recording breakdown) is
        // still usable for the vote, so it becomes one anonymous recording.
        let recordings = (best.recordings ?? []).map { recording in
            AcoustIDRecording(
                id: recording.id,
                releaseIDs: (recording.releases ?? []).map(\.id)
            )
        }
        if !recordings.isEmpty { return recordings }

        let topLevel = (best.releases ?? []).map(\.id)
        return topLevel.isEmpty ? [] : [AcoustIDRecording(id: "", releaseIDs: topLevel)]
    }

    /// Release MBIDs, best-first, by how many of an album's files place a
    /// recording on them.
    ///
    /// Each file gets one vote per release however many of its recordings
    /// appear there, so a track whose recording is listed on forty
    /// compilations cannot outvote the album everybody agrees on. Ties keep
    /// first-seen order, which is AcoustID's own relevance ordering.
    public static func rankReleases(_ perFileRecordings: [[AcoustIDRecording]]) -> [String] {
        var votes: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var seq = 0

        for recordings in perFileRecordings {
            var ballot: Set<String> = []
            for recording in recordings {
                ballot.formUnion(recording.releaseIDs)
            }
            for releaseID in ballot where !releaseID.isEmpty {
                votes[releaseID, default: 0] += 1
                if firstSeen[releaseID] == nil {
                    firstSeen[releaseID] = seq
                    seq += 1
                }
            }
        }

        return votes.keys.sorted { lhs, rhs in
            let lv = votes[lhs] ?? 0
            let rv = votes[rhs] ?? 0
            if lv != rv { return lv > rv }
            return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
        }
    }

    /// How many of `perFileRecordings` place a recording on `releaseID`, as a
    /// share of the files that AcoustID recognised at all. This is DEEP SCAN's
    /// confidence: it is measured on the audio, not on the tags the audio is
    /// there to correct.
    public static func voteShare(of releaseID: String, in perFileRecordings: [[AcoustIDRecording]]) -> Double {
        guard !perFileRecordings.isEmpty else { return 0 }
        let agreeing = perFileRecordings.filter { recordings in
            recordings.contains { $0.releaseIDs.contains(releaseID) }
        }.count
        return Double(agreeing) / Double(perFileRecordings.count)
    }

    // MARK: Wire format

    struct Response: Decodable {
        let status: String?
        let results: [Result]?
    }

    struct ErrorEnvelope: Decodable {
        let status: String?
        let error: ServiceError?
    }

    struct ServiceError: Decodable {
        let code: Int?
        let message: String?
    }

    struct Result: Decodable {
        let id: String?
        let score: Double?
        let recordings: [Recording]?
        let releases: [ReleaseRef]?
    }

    struct Recording: Decodable {
        let id: String
        let releases: [ReleaseRef]?
    }

    struct ReleaseRef: Decodable {
        let id: String
    }
}
