import Foundation

/// What the Artwork Search release list knows about one release's Cover Art
/// Archive holding.
///
/// Three states, because the row has to tell them apart: a count still on its
/// way, a count that came back, and a count that couldn't be had. Folding the
/// last into "no images" is how a release with 23 scans came to read
/// NO IMAGES whenever archive.org had a bad night.
public enum CoverArtCount: Equatable, Sendable {
    case pending
    case known(CoverArtSummary)
    case unknown

    /// A lookup's answer: a summary, or nil for one that couldn't be had.
    public init(lookup summary: CoverArtSummary?) {
        self = summary.map(CoverArtCount.known) ?? .unknown
    }

    public var summary: CoverArtSummary? {
        if case let .known(summary) = self { return summary }
        return nil
    }
}

/// How the release list is ordered.
public enum ArtworkReleaseSort: Equatable, Sendable {
    /// MusicBrainz's own relevance order.
    case relevance
    /// Oldest first; undated releases last.
    case year
    /// The art the release actually carries: measured front size, then
    /// whether it has a front at all, then how many images it holds.
    case art
}

/// The release list's filtering, sorting, grouping and "best match" badge.
///
/// These were computed inside the sheet's view body, once per row: every row
/// re-filtered and re-sorted the whole list to ask whether it was the best
/// match. They are decidable values, so they live here, are computed once per
/// render, and are tested.
public enum ArtworkReleaseList {

    /// Every medium format in the results, for the MEDIA menu. A release with
    /// a CD and a DVD offers both.
    public static func formats(in releases: [MBReleaseCandidate]) -> [String] {
        Array(Set(releases.flatMap(\.formats))).sorted()
    }

    public static func countries(in releases: [MBReleaseCandidate]) -> [String] {
        Array(Set(releases.compactMap(\.country))).sorted()
    }

    /// The releases the list draws, in the order it draws them.
    ///
    /// A MEDIA filter matches a release carrying that format on any of its
    /// media, which is what the menu offers: the menu lists every format, so
    /// filtering by the first medium alone hid a CD + DVD set under "DVD".
    public static func displayed(_ releases: [MBReleaseCandidate],
                                 media: String?,
                                 country: String?,
                                 sort: ArtworkReleaseSort,
                                 counts: [String: CoverArtCount] = [:],
                                 frontSizes: [String: ArtworkDimensions] = [:]) -> [MBReleaseCandidate] {
        var indexed = Array(releases.enumerated())
        if let media { indexed = indexed.filter { $0.element.formats.contains(media) } }
        if let country { indexed = indexed.filter { $0.element.country == country } }

        // Ties keep MusicBrainz's order: `sort` makes no stability promise,
        // and a list that reshuffles equal rows as counts land reads as noise.
        switch sort {
        case .relevance:
            break
        case .year:
            indexed.sort { lhs, rhs in
                let l = lhs.element.year ?? Int.max, r = rhs.element.year ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
        case .art:
            func key(_ release: MBReleaseCandidate) -> (Int, Int, Int) {
                let summary = counts[release.id]?.summary
                return (frontSizes[release.id]?.longEdge ?? 0,
                        summary?.hasFront == true && summary?.darkened == false ? 1 : 0,
                        summary?.available ?? 0)
            }
            indexed.sort { lhs, rhs in
                let l = key(lhs.element), r = key(rhs.element)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
        }
        return indexed.map(\.element)
    }

    /// One edition's run of releases.
    public struct Group: Equatable, Sendable {
        public let edition: String
        public let releases: [MBReleaseCandidate]
    }

    /// `displayed` releases grouped by edition, "Standard" first, then
    /// alphabetical, each group keeping the list's own order. The header's
    /// count is the group's length, so the two can't disagree.
    public static func grouped(_ displayed: [MBReleaseCandidate]) -> [Group] {
        var order: [String] = []
        var members: [String: [MBReleaseCandidate]] = [:]
        for release in displayed {
            let label = edition(of: release)
            if members[label] == nil { order.append(label) }
            members[label, default: []].append(release)
        }
        return order
            .sorted { lhs, rhs in
                if lhs == standardEdition { return rhs != standardEdition }
                if rhs == standardEdition { return false }
                return lhs < rhs
            }
            .map { Group(edition: $0, releases: members[$0] ?? []) }
    }

    public static let standardEdition = "Standard"

    /// A coarse edition label from the title and disambiguation. Order
    /// matters: "super deluxe" before "deluxe", "remaster" catches
    /// "remastered".
    public static func edition(of release: MBReleaseCandidate) -> String {
        let hay = (release.title + " " + (release.disambiguation ?? "")).lowercased()
        let map: [(String, String)] = [
            ("anniversary", "Anniversary"),
            ("super deluxe", "Deluxe"),
            ("deluxe", "Deluxe"),
            ("remaster", "Remastered"),
            ("expanded", "Expanded"),
            ("special", "Special Edition"),
            ("collector", "Collector's"),
            ("limited", "Limited"),
            ("bonus", "Bonus"),
            ("reissue", "Reissue"),
            ("mono", "Mono")
        ]
        for (needle, label) in map where hay.contains(needle) { return label }
        return standardEdition
    }

    /// The release that best matches the album being dressed, badged so the
    /// user reaches for the right edition. Scored on metadata only (title,
    /// official status, format, year). Nil unless something scores a real
    /// title match.
    public static func bestMatchID(in releases: [MBReleaseCandidate],
                                   albumTitle: String,
                                   albumYear: Int?,
                                   albumMedia: MediaFormat?) -> String? {
        func score(_ release: MBReleaseCandidate) -> Int {
            matchScore(release, albumTitle: albumTitle, albumYear: albumYear, albumMedia: albumMedia)
        }
        guard let best = releases.max(by: { score($0) < score($1) }),
              score(best) >= 40 else { return nil }
        return best.id
    }

    static func matchScore(_ release: MBReleaseCandidate,
                           albumTitle: String,
                           albumYear: Int?,
                           albumMedia: MediaFormat?) -> Int {
        var score = 0
        let want = albumTitle.lowercased().trimmingCharacters(in: .whitespaces)
        let got = release.title.lowercased().trimmingCharacters(in: .whitespaces)
        if got == want {
            score += 100
        } else if !want.isEmpty && (got.contains(want) || want.contains(got)) {
            score += 40
        }
        if release.status == "Official" { score += 30 }
        let formats = release.formats.map { $0.lowercased() }
        switch albumMedia {
        case .some(.cd) where formats.contains(where: { $0.contains("cd") }):
            score += 20
        case .some(.vinyl) where formats.contains(where: { $0.contains("vinyl") || $0.contains("lp") }):
            score += 20
        default:
            break
        }
        if let wanted = albumYear, let year = release.year {
            if year == wanted { score += 25 } else if abs(year - wanted) <= 1 { score += 10 }
        }
        return score
    }
}

/// Where one source of scans stands for the release on screen.
public enum ArtworkSourceLoad: Equatable, Sendable {
    /// Not asked: no release picked, or Discogs switched off.
    case idle
    case loading
    case loaded(count: Int)
    case failed(String)

    public var isLoading: Bool { self == .loading }
    public var failure: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// What the artwork grid shows in place of tiles, decided from both sources at
/// once. The grid used to read one flag per stage, so while Discogs was still
/// looking it already said "No scans: this release has no artwork", and a
/// failed archive request skipped Discogs altogether and showed only the
/// archive's error.
public enum ArtworkGridStatus: Equatable, Sendable {
    /// There is something to draw. Per-source progress goes in the toolbar.
    case grid
    case loading(detail: String)
    case empty(detail: String)
    case failed(detail: String)

    public static func resolve(imageCount: Int,
                               archive: ArtworkSourceLoad,
                               discogs: ArtworkSourceLoad) -> ArtworkGridStatus {
        if imageCount > 0 { return .grid }

        switch (archive, discogs) {
        case (.loading, .loading):
            return .loading(detail: "Asking the Cover Art Archive and Discogs.")
        case (.loading, _):
            return .loading(detail: "Reading this release from the Cover Art Archive.")
        case (.failed, .loading):
            return .loading(detail: "The Cover Art Archive didn't answer. Still asking Discogs.")
        case (_, .loading):
            return .loading(detail: "The Cover Art Archive has no images for this release. Still asking Discogs.")
        default:
            break
        }

        switch (archive.failure, discogs) {
        case let (archiveError?, .failed):
            return .failed(detail: "\(archiveError) Discogs didn't answer either.")
        case let (archiveError?, .loaded):
            return .failed(detail: "\(archiveError) Discogs has no scans of this pressing.")
        case let (archiveError?, _):
            return .failed(detail: archiveError)
        case (nil, .failed(let discogsError)):
            return .failed(detail: "The Cover Art Archive has no images for this release, and Discogs didn't answer. \(discogsError)")
        case (nil, .loaded):
            return .empty(detail: "Neither the Cover Art Archive nor Discogs has images for this release.")
        default:
            return .empty(detail: "The Cover Art Archive has no images for this release.")
        }
    }
}
