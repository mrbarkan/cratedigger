import Foundation

/// DEEP SCAN: identify an album by what it *sounds* like, not by what its tags
/// claim.
///
/// Text matching (`MetadataMatchService`) searches with the artist and album
/// already on the files, so it is helpless in the one case that matters most —
/// a rip with no tags, or tags belonging to a different record. This path
/// starts from the audio instead:
///
/// 1. `fpcalc` fingerprints each file (Chromaprint),
/// 2. AcoustID turns each fingerprint into MusicBrainz recordings,
/// 3. the files vote on which release they all appear on,
/// 4. MusicBrainz supplies the winning release's real track list,
/// 5. the existing `ReleaseScorer` turns it into per-track proposals, paired by
///    recording MBID so each file lands on the track it genuinely is.
///
/// The score is the vote share, not text similarity: a fingerprint match is
/// trustworthy precisely because it never looked at the tags.
///
/// `@unchecked Sendable`: the only non-Sendable member is the fingerprinter's
/// injected `CommandRunning`, which in production is the stateless
/// `ProcessCommandRunner`.
/// What a deep scan came back with.
///
/// `matches` empty with `serviceError` nil means the audio genuinely matched
/// nothing. `serviceError` set means AcoustID turned us away and the audio was
/// never really looked at, which is a different sentence to put in front of a
/// user.
public struct FingerprintMatchResult: Sendable {
    public let matches: [ReleaseMatch]
    public let serviceError: AcoustIDError?

    public init(matches: [ReleaseMatch], serviceError: AcoustIDError? = nil) {
        self.matches = matches
        self.serviceError = serviceError
    }
}

public struct FingerprintMatchService: @unchecked Sendable {

    /// Fingerprinting decodes audio, so every extra file is real work. A vote is
    /// settled long before the twelfth track.
    // ponytail: fixed cap. If box sets start matching the wrong disc, sample
    // across the album rather than taking the first twelve.
    public static let maxTracksPerAlbum = 12

    /// How many voted releases get a MusicBrainz fetch. Past the third, the
    /// vote has already spoken.
    public static let releaseDetailLimit = 3

    /// A release needs this share of the album's recognised files to be offered
    /// at all. Half the album agreeing is a real edition; two stray tracks off a
    /// compilation are not.
    public static let minimumVoteShare = 0.5

    private let fingerprinter: AudioFingerprintService
    private let acoustID: AcoustIDClient
    private let musicBrainz: MusicBrainzReleaseClient

    public init(
        fpcalcURL: URL,
        runner: CommandRunning = ProcessCommandRunner(timeoutSeconds: 30),
        session: URLSession? = nil,
        apiKey: String = AcoustIDClient.applicationKey
    ) {
        self.fingerprinter = AudioFingerprintService(fpcalcURL: fpcalcURL, runner: runner)
        self.acoustID = AcoustIDClient(session: session, apiKey: apiKey)
        self.musicBrainz = MusicBrainzReleaseClient(session: session)
    }

    /// Injection seam for tests, which supply their own fingerprinter and
    /// clients rather than spawning fpcalc.
    init(
        fingerprinter: AudioFingerprintService,
        acoustID: AcoustIDClient,
        musicBrainz: MusicBrainzReleaseClient
    ) {
        self.fingerprinter = fingerprinter
        self.acoustID = acoustID
        self.musicBrainz = musicBrainz
    }

    /// Releases the audio says these tracks came from, best-first.
    ///
    /// `progress` reports (files fingerprinted, files to fingerprint) so a long
    /// album can say what it is doing. An empty result means the audio matched
    /// nothing, which the caller should report honestly rather than falling back
    /// to a guess.
    public func match(
        for tracks: [LoadedTrack],
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> FingerprintMatchResult {
        let sampled = Array(tracks.prefix(Self.maxTracksPerAlbum))
        guard !sampled.isEmpty else { return FingerprintMatchResult(matches: []) }

        var identified: [(track: LoadedTrack, recordings: [AcoustIDRecording])] = []
        var serviceError: AcoustIDError?
        for (offset, track) in sampled.enumerated() {
            if Task.isCancelled { return FingerprintMatchResult(matches: []) }
            progress(offset + 1, sampled.count)

            // fpcalc blocks while it decodes; the cooperative pool is only as
            // wide as the CPU, so this has to leave it (see BlockingWork).
            guard let fingerprint = try? await BlockingWork.run({
                try fingerprinter.fingerprint(track.track.fileURL)
            }) else {
                AppLog.library.warning("fpcalc could not fingerprint \(track.track.fileURL.lastPathComponent, privacy: .public)")
                continue
            }

            do {
                let recordings = try await acoustID.recordings(for: fingerprint)
                if !recordings.isEmpty { identified.append((track, recordings)) }
            } catch let error as AcoustIDError {
                // Being refused is not "this track is obscure": every remaining
                // file would be refused too, so stop and report it.
                serviceError = error
                break
            } catch {
                AppLog.library.warning(
                    "AcoustID lookup failed for \(track.track.fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        if let serviceError { return FingerprintMatchResult(matches: [], serviceError: serviceError) }
        guard !identified.isEmpty else { return FingerprintMatchResult(matches: []) }

        let ballots = identified.map(\.recordings)
        let ranked = AcoustIDClient.rankReleases(ballots)
        guard !ranked.isEmpty else { return FingerprintMatchResult(matches: []) }

        // Every file's identified recordings, so the proposal builder can pair
        // each one to its actual slot on whichever release wins.
        var recordingIDs: [UUID: Set<String>] = [:]
        for entry in identified {
            recordingIDs[entry.track.track.id] = Set(entry.recordings.map(\.id).filter { !$0.isEmpty })
        }

        var matches: [ReleaseMatch] = []
        for releaseID in ranked.prefix(Self.releaseDetailLimit) {
            if Task.isCancelled { break }
            let share = AcoustIDClient.voteShare(of: releaseID, in: ballots)
            guard share >= Self.minimumVoteShare else { continue }

            guard let candidate = try? await musicBrainz.release(id: releaseID) else {
                AppLog.library.warning("MusicBrainz release \(releaseID, privacy: .public) could not be fetched for DEEP SCAN")
                continue
            }

            // Re-badge: the data is MusicBrainz's, but how we got here is what
            // the review sheet needs to tell the user.
            var audioCandidate = candidate
            audioCandidate.source = .acoustID

            let match = ReleaseMatch(
                candidate: audioCandidate,
                score: share,
                trackProposals: ReleaseScorer.proposals(
                    from: audioCandidate,
                    for: tracks,
                    recordingIDs: recordingIDs
                )
            )
            if match.hasChanges { matches.append(match) }
        }

        return FingerprintMatchResult(matches: matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.tracks.count > rhs.candidate.tracks.count
        })
    }
}
