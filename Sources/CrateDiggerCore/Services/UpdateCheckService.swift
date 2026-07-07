import Foundation

/// A semver version parsed from a release tag ("v1.0.0-rc.33", "1.0.0").
/// Ordering follows semver 2.0: the core triple compares numerically, a stable
/// release outranks any prerelease of the same triple, and prerelease
/// identifiers compare numerically when both sides are numeric (rc.33 > rc.4).
public struct SemanticVersion: Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Empty = stable release. ["rc", "33"] for "-rc.33".
    public let prerelease: [String]

    public init?(tag: String) {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Build metadata ("+…") never affects precedence — drop it.
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }

        let core: Substring
        if let dash = s.firstIndex(of: "-") {
            core = s[..<dash]
            prerelease = s[s.index(after: dash)...].split(separator: ".").map(String.init)
        } else {
            core = s[...]
            prerelease = []
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

extension SemanticVersion: Comparable {
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false        // stable ≥ anything with the same triple
        case (false, true): return true     // prerelease < stable
        case (false, false): break
        }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            switch (Int(l), Int(r)) {
            case let (ln?, rn?): return ln < rn
            case (_?, nil): return true     // numeric identifiers rank below alphanumeric
            case (nil, _?): return false
            case (nil, nil): return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// One published release, reduced to what the update alert needs.
public struct AppRelease: Hashable, Sendable {
    public let tagName: String
    public let version: SemanticVersion
    public let name: String
    public let notes: String
    public let isPrerelease: Bool
    public let htmlURL: URL
    public let dmgAssetURL: URL?
}

public enum UpdateCheckResult: Hashable, Sendable {
    case upToDate
    case updateAvailable(AppRelease)
}

public enum UpdateCheckError: Error, LocalizedError {
    case badResponse
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The update server did not respond as expected."
        case .decodingFailed(let message):
            return "The release feed could not be read: \(message)"
        }
    }
}

/// Injection point so tests feed fixture JSON instead of hitting GitHub.
public protocol UpdateFeedFetching: Sendable {
    func fetchReleasesJSON() async throws -> Data
}

/// The real feed: the GitHub Releases list for this repo. Not
/// `/releases/latest` — that endpoint only serves stable releases and 404s
/// while everything published is still a prerelease.
public struct GitHubReleaseFeed: UpdateFeedFetching {
    private static let feedURL = URL(
        string: "https://api.github.com/repos/mrbarkan/cratedigger/releases?per_page=10"
    )!

    /// The human-facing releases listing (all releases, notes, and DMGs) — for
    /// "browse updates" links in the UI. Distinct from the API `feedURL`.
    public static let releasesPageURL = URL(
        string: "https://github.com/mrbarkan/cratedigger/releases"
    )!

    public init() {}

    public func fetchReleasesJSON() async throws -> Data {
        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.badResponse
        }
        return data
    }
}

public struct UpdateCheckService: Sendable {
    private let feed: UpdateFeedFetching

    public init(feed: UpdateFeedFetching = GitHubReleaseFeed()) {
        self.feed = feed
    }

    /// `includePrereleases` follows the running app's channel: RC builds are
    /// offered RCs, a final release only ever sees stable releases.
    public func checkForUpdate(
        currentVersion: SemanticVersion,
        includePrereleases: Bool
    ) async throws -> UpdateCheckResult {
        let data = try await feed.fetchReleasesJSON()
        let releases = try Self.parseReleases(data)
        guard let best = Self.newestEligible(releases, includePrereleases: includePrereleases),
              currentVersion < best.version
        else { return .upToDate }
        return .updateAvailable(best)
    }

    /// Decodes the GitHub payload, dropping drafts and any release whose tag
    /// isn't parseable semver.
    static func parseReleases(_ data: Data) throws -> [AppRelease] {
        let decoded: [GitHubRelease]
        do {
            decoded = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateCheckError.decodingFailed(error.localizedDescription)
        }
        return decoded.compactMap { release in
            guard !release.draft,
                  let version = SemanticVersion(tag: release.tagName),
                  let htmlURL = URL(string: release.htmlURL)
            else { return nil }
            let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            return AppRelease(
                tagName: release.tagName,
                version: version,
                name: release.name ?? release.tagName,
                notes: release.body ?? "",
                isPrerelease: release.prerelease,
                htmlURL: htmlURL,
                dmgAssetURL: dmg.flatMap { URL(string: $0.browserDownloadURL) }
            )
        }
    }

    static func newestEligible(_ releases: [AppRelease], includePrereleases: Bool) -> AppRelease? {
        releases
            .filter { includePrereleases || !$0.isPrerelease }
            .max { $0.version < $1.version }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
    }
}
