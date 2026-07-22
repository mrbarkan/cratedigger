import Foundation

/// Fuzzy string comparison for release/track matching. Titles in the wild
/// disagree on case, punctuation, and leading articles far more often than they
/// disagree on substance ("The Beatles" vs "Beatles", "Power, Corruption & Lies"
/// vs "Power Corruption and Lies"), so normalize those away before measuring
/// edit distance.
public enum StringSimilarity {

    /// 0 (nothing in common) … 1 (identical after normalization).
    public static func score(_ lhs: String, _ rhs: String) -> Double {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }

        let distance = levenshtein(Array(a), Array(b))
        let longest = max(a.count, b.count)
        return max(0, 1 - Double(distance) / Double(longest))
    }

    /// Lowercased, punctuation stripped, "&" spelled out, leading article
    /// dropped, whitespace collapsed.
    static func normalized(_ value: String) -> String {
        var text = value.lowercased()
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = text.replacingOccurrences(of: "_", with: " ")
        text = String(text.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
        let words = text.split(separator: " ").map(String.init)
        let meaningful = (words.first == "the" || words.first == "a" || words.first == "an") && words.count > 1
            ? Array(words.dropFirst())
            : words
        return meaningful.joined(separator: " ")
    }

    /// Classic edit distance, two-row variant (only the previous row is needed).
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Ranks release candidates against what we know about a selection, and turns
/// the winner into per-track tag proposals.
///
/// Pure value work — no network, no filesystem — so the judgement that decides
/// what gets written to a user's files is fully unit-testable.
public enum ReleaseScorer {

    /// How far a track's runtime may drift from the release's before it counts
    /// as a different recording. Rips and database entries routinely disagree by
    /// a second or two (gapless trims, silence handling).
    private static let durationToleranceSeconds: Double = 5
    /// Past this the tracks are unrelated, not merely a different edition.
    private static let durationMismatchSeconds: Double = 30

    // MARK: - Scoring

    /// 0…1 confidence that `candidate` is the release the selection came from.
    ///
    /// A weighted mean over whatever signals the query actually has: artist and
    /// album names, how well the track count agrees, and how closely runtimes
    /// line up. Components the query can't speak to (an untagged album name, a
    /// source with no durations) drop out of the mean rather than scoring zero —
    /// otherwise a perfectly good match for an untagged rip would be buried.
    public static func score(_ candidate: ReleaseCandidate, against query: ReleaseQuery) -> Double {
        var components: [(value: Double, weight: Double)] = []

        if let artist = query.artist, !artist.isEmpty {
            components.append((StringSimilarity.score(artist, candidate.artist), 0.3))
        }
        if let album = query.album, !album.isEmpty {
            components.append((StringSimilarity.score(album, candidate.title), 0.4))
        }
        if let titleScore = titleAgreement(candidate, query) {
            components.append((titleScore, 0.3))
        }
        if let countScore = trackCountAgreement(candidate, query) {
            components.append((countScore, 0.15))
        }
        if let durationScore = durationAgreement(candidate, query) {
            components.append((durationScore, 0.15))
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        return components.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
    }

    /// Mean similarity of each queried track title to its best match on the
    /// release. `nil` when the selection has no titles to compare.
    private static func titleAgreement(_ candidate: ReleaseCandidate, _ query: ReleaseQuery) -> Double? {
        let titles = query.tracks.compactMap { $0.title }.filter { !$0.isEmpty }
        guard !titles.isEmpty, !candidate.tracks.isEmpty else { return nil }

        let scores = titles.map { title in
            candidate.tracks.map { StringSimilarity.score(title, $0.title) }.max() ?? 0
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// 1 when the release has exactly as many tracks as the selection, falling
    /// off as the gap widens. `nil` when the release doesn't say.
    ///
    /// A partial selection (3 tracks off a 12-track album) is legitimate, so a
    /// release with *more* tracks than the selection is only mildly penalized;
    /// a release with *fewer* is more suspicious — it can't contain them all.
    private static func trackCountAgreement(_ candidate: ReleaseCandidate, _ query: ReleaseQuery) -> Double? {
        let releaseCount = candidate.totalTracks ?? (candidate.tracks.isEmpty ? nil : candidate.tracks.count)
        guard let releaseCount, releaseCount > 0, !query.tracks.isEmpty else { return nil }

        let selectionCount = query.tracks.count
        if releaseCount == selectionCount { return 1 }
        if releaseCount > selectionCount {
            return max(0, 1 - Double(releaseCount - selectionCount) / Double(releaseCount) * 0.5)
        }
        return max(0, Double(releaseCount) / Double(selectionCount) * 0.5)
    }

    /// Mean per-track runtime agreement over tracks we can pair up by number.
    /// `nil` when either side lacks durations.
    private static func durationAgreement(_ candidate: ReleaseCandidate, _ query: ReleaseQuery) -> Double? {
        var scores: [Double] = []
        for queryTrack in query.tracks {
            guard let duration = queryTrack.durationSeconds, duration > 0 else { continue }
            let releaseTrack = queryTrack.trackNumber.flatMap { number in
                candidate.tracks.first { $0.position == number }
            } ?? bestDurationMatch(duration, in: candidate.tracks)
            guard let releaseDuration = releaseTrack?.durationSeconds, releaseDuration > 0 else { continue }

            let delta = abs(releaseDuration - duration)
            if delta <= durationToleranceSeconds {
                scores.append(1)
            } else if delta >= durationMismatchSeconds {
                scores.append(0)
            } else {
                let span = durationMismatchSeconds - durationToleranceSeconds
                scores.append(1 - (delta - durationToleranceSeconds) / span)
            }
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private static func bestDurationMatch(_ duration: Double, in tracks: [ReleaseTrack]) -> ReleaseTrack? {
        tracks
            .filter { ($0.durationSeconds ?? 0) > 0 }
            .min { abs(($0.durationSeconds ?? 0) - duration) < abs(($1.durationSeconds ?? 0) - duration) }
    }

    // MARK: - Track mapping & proposals

    /// Pair each selected track with a track on the release, then describe what
    /// accepting the release would change.
    ///
    /// Pairing prefers, in order: the track's own number, the closest title (with
    /// runtime as the tie-breaker), and finally selection order. Each release
    /// track is claimed at most once, so two files that look alike can't both
    /// become track 1.
    public static func proposals(from candidate: ReleaseCandidate, for tracks: [LoadedTrack]) -> [TrackTagProposal] {
        var available = candidate.tracks
        var pairings: [(index: Int, releaseTrack: ReleaseTrack?)] = []

        // Pass 1: explicit track numbers — the strongest signal, so let them
        // claim their slots before fuzzier matching gets a look in.
        var unmatched: [Int] = []
        for (index, track) in tracks.enumerated() {
            guard let number = track.metadata.trackNumber ?? track.track.trackNumber,
                  let slot = available.firstIndex(where: {
                      $0.position == number && $0.discNumber == (track.metadata.discNumber ?? 1)
                  }) ?? available.firstIndex(where: { $0.position == number })
            else {
                unmatched.append(index)
                continue
            }
            pairings.append((index, available.remove(at: slot)))
        }

        // Pass 2: by title, best-first, so the strongest title match claims its
        // track before a weaker one can take it.
        let titleRanked = unmatched
            .map { index -> (index: Int, best: Double) in
                let title = tracks[index].metadata.title ?? tracks[index].track.title
                let best = available.map { StringSimilarity.score(title, $0.title) }.max() ?? 0
                return (index, best)
            }
            .sorted { $0.best > $1.best }

        var stillUnmatched: [Int] = []
        for (index, best) in titleRanked {
            let track = tracks[index]
            let title = track.metadata.title ?? track.track.title
            guard best >= 0.6,
                  let slot = bestTitleSlot(title: title, duration: track.track.durationSeconds, in: available)
            else {
                stillUnmatched.append(index)
                continue
            }
            pairings.append((index, available.remove(at: slot)))
        }

        // Pass 3: whatever's left, in order — a last resort for files with
        // neither a usable number nor a recognizable title.
        for index in stillUnmatched.sorted() {
            pairings.append((index, available.isEmpty ? nil : available.removeFirst()))
        }

        return pairings
            .sorted { $0.index < $1.index }
            .map { pairing in
                proposal(for: tracks[pairing.index], releaseTrack: pairing.releaseTrack, candidate: candidate)
            }
    }

    private static func bestTitleSlot(title: String, duration: Double, in tracks: [ReleaseTrack]) -> Int? {
        var bestIndex: Int?
        var bestScore = 0.0
        for (index, track) in tracks.enumerated() {
            var score = StringSimilarity.score(title, track.title)
            // Tie-break on runtime: two same-named tracks (a reprise, a remix)
            // are told apart by how long they run.
            if let releaseDuration = track.durationSeconds, duration > 0, releaseDuration > 0 {
                score += abs(releaseDuration - duration) <= durationToleranceSeconds ? 0.01 : 0
            }
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestScore >= 0.6 ? bestIndex : nil
    }

    /// Merge one release track over one file's tags. Fields the release knows
    /// nothing about keep their current value — a lookup should never blank out
    /// what the file already had.
    private static func proposal(
        for track: LoadedTrack,
        releaseTrack: ReleaseTrack?,
        candidate: ReleaseCandidate
    ) -> TrackTagProposal {
        let current = track.metadata
        var proposed = current

        if let releaseTrack {
            proposed.title = releaseTrack.title
            proposed.artist = releaseTrack.artist ?? candidate.artist
            proposed.trackNumber = releaseTrack.position
        }
        proposed.albumArtist = candidate.artist
        proposed.album = candidate.title
        if let totalTracks = candidate.totalTracks { proposed.trackTotal = totalTracks }
        if let year = candidate.year { proposed.year = year }
        if let genre = candidate.genre { proposed.genre = genre }

        // Disc numbers only carry meaning on a multi-disc release. Stamping
        // "disc 1 of 1" onto every track of an ordinary album would fill the
        // review sheet with changes nobody asked for — so leave them alone
        // unless the release really has several discs, or the file already
        // tracks a disc number worth correcting.
        let isMultiDisc = (candidate.totalDiscs ?? 1) > 1
            || (candidate.tracks.map(\.discNumber).max() ?? 1) > 1
        if isMultiDisc || current.discNumber != nil {
            if let releaseTrack { proposed.discNumber = releaseTrack.discNumber }
            if let totalDiscs = candidate.totalDiscs { proposed.discTotal = totalDiscs }
        }

        let changed = MetadataRepairField.allCases.filter { field in
            MetadataRepairPlanner.value(of: field, in: current) != MetadataRepairPlanner.value(of: field, in: proposed)
        }

        return TrackTagProposal(
            trackID: track.track.id,
            trackTitle: track.track.title,
            current: current,
            proposed: proposed,
            changedFields: changed
        )
    }
}
