import Foundation

/// Finds the release a selection of tracks came from, and says what accepting it
/// would change. The lookup half of FIX TAGS.
///
/// Nothing here writes: the service proposes, the review sheet disposes. Every
/// judgement it makes (what to search for, which release wins, which fields
/// actually differ) is pure value work in `ReleaseScorer` /
/// `MetadataNormalization`, so the logic deciding what lands in a user's files
/// is unit-tested rather than trusted.
public struct MetadataMatchService: Sendable {

    /// Below this, a candidate is noise — the user gets an honest "no match"
    /// instead of a plausible-looking wrong album.
    public static let minimumScore = 0.62

    /// How many of each source's results get a track-list lookup. Every extra
    /// one costs a request (and a second of MusicBrainz throttle), and results
    /// past the third are rarely the answer.
    private static let detailLimit = 3

    private let providers: [any ReleaseMetadataProvider]

    public init(providers: [any ReleaseMetadataProvider]) {
        self.providers = providers
    }

    /// The real thing: MusicBrainz for depth, iTunes for speed and genre.
    public static func live(session: URLSession? = nil) -> MetadataMatchService {
        MetadataMatchService(providers: [
            MusicBrainzReleaseClient(session: session),
            ITunesReleaseClient(session: session)
        ])
    }

    // MARK: - Query building

    /// What to search for, given a selection.
    ///
    /// Tags first; where they're blank, fall back to the file and folder names,
    /// which are often the only honest signal left on an untagged rip
    /// ("Artist - Album (1997)/03 Title.flac"). Album artist beats track artist
    /// for the release-level query, since that's what a release is filed under.
    public static func query(for tracks: [LoadedTrack]) -> ReleaseQuery {
        guard !tracks.isEmpty else { return ReleaseQuery() }

        let folder = MetadataNormalization.albumFolderComponents(
            tracks[0].track.fileURL.deletingLastPathComponent().lastPathComponent
        )

        let artist = mostCommon(tracks.map { clean($0.metadata.albumArtist) })
            ?? mostCommon(tracks.map { clean($0.metadata.artist) })
            ?? folder.artist
        let album = mostCommon(tracks.map { clean($0.metadata.album) }) ?? folder.album
        let year = mostCommon(tracks.compactMap { $0.metadata.year }) ?? folder.year

        let queryTracks = tracks.map { loaded in
            QueryTrack(
                title: clean(loaded.metadata.title)
                    ?? MetadataNormalization.title(
                        fromFilename: loaded.track.fileURL.deletingPathExtension().lastPathComponent
                    ),
                trackNumber: loaded.metadata.trackNumber
                    ?? MetadataNormalization.trackNumber(
                        fromFilename: loaded.track.fileURL.deletingPathExtension().lastPathComponent
                    ),
                durationSeconds: loaded.track.durationSeconds > 0 ? loaded.track.durationSeconds : nil
            )
        }

        return ReleaseQuery(artist: artist, album: album, year: year, tracks: queryTracks)
    }

    /// Split a selection into per-album groups using the same
    /// `albumFolderKey` invariant the browser index and conversion planner
    /// share — FIX TAGS must agree with the rest of the app on "what an album
    /// is". Groups come back in first-appearance order.
    public static func partitionByAlbum(_ tracks: [LoadedTrack]) -> [[LoadedTrack]] {
        let planner = OutputPathPlanner()
        var order: [AlbumFolderKey] = []
        var byKey: [AlbumFolderKey: [LoadedTrack]] = [:]
        for track in tracks {
            let key = planner.albumFolderKey(for: track)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(track)
        }
        return order.compactMap { byKey[$0] }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The value most tracks agree on. An album's stray mistagged track
    /// shouldn't decide what the whole selection is searched as.
    private static func mostCommon<T: Hashable>(_ values: [T?]) -> T? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        let counts = present.reduce(into: [T: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { lhs, rhs in lhs.value < rhs.value }?.key
    }

    // MARK: - Matching

    /// Every plausible release for `tracks`, best-first.
    ///
    /// Sources are queried concurrently and failures are swallowed per source —
    /// if MusicBrainz is down, iTunes results still come back. An empty result
    /// means "nothing worth showing", which the caller reports as no match.
    public func match(for tracks: [LoadedTrack]) async -> [ReleaseMatch] {
        let query = Self.query(for: tracks)
        guard !query.isEmpty else { return [] }
        return await match(query: query, for: tracks)
    }

    func match(query: ReleaseQuery, for tracks: [LoadedTrack]) async -> [ReleaseMatch] {
        let candidates = await withTaskGroup(of: [ReleaseCandidate].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return try await provider.searchReleases(query: query, detailLimit: Self.detailLimit)
                    } catch {
                        AppLog.library.warning(
                            "\(provider.source.rawValue, privacy: .public) release lookup failed: \(String(describing: error), privacy: .public)"
                        )
                        return []
                    }
                }
            }
            var all: [ReleaseCandidate] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        return candidates
            .map { ReleaseMatch(
                candidate: $0,
                score: ReleaseScorer.score($0, against: query),
                trackProposals: ReleaseScorer.proposals(from: $0, for: tracks)
            ) }
            .filter { $0.score >= Self.minimumScore && $0.hasChanges }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // A tie on score goes to the source with the fuller record.
                return lhs.candidate.tracks.count > rhs.candidate.tracks.count
            }
    }
}
