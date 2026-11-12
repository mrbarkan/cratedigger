import Foundation

/// How sure a candidate is to be the artist on the device (spec D2).
public enum ArtistPictureVerdict: Equatable, Sendable {
    /// The name keys as ours and one of its albums is one of ours: taken without asking.
    case confident
    /// The name keys as ours but no album confirms it: held for the owner to pick.
    case uncertain
    /// The player would not take this name for ours.
    case noMatch
}

/// The match rule (D2). A candidate is `noMatch` unless the player would take
/// its name for ours (`PodBoxArtName.matches`). It is `confident` when, in
/// addition, one device album title equals one candidate album title after
/// dropping trailing parenthesised or bracketed suffixes from both
/// (`OK Computer (Remastered)` is `OK Computer`) and folding with
/// `PodBoxArtName.folded` (case, accents and punctuation ignored).
///
/// Titles that say nothing about which act it is never count: a title that
/// folds to nothing, a self-titled album (`Boston` by Boston), and generic
/// ones (`Greatest Hits`, `Best Of…`, `Live`, `Gold`, …), which many acts of
/// one name share. Anything else is `uncertain`. The finder still accepts a
/// confident candidate only when it is the only confident one of its source.
public enum ArtistPictureMatcher {
    /// Folded titles too common to tell two acts apart.
    static let genericTitles: Set<String> = [
        "greatesthits", "greatest", "hits", "best", "bestof", "verybestof", "essential", "essentials",
        "live", "liveinconcert", "inconcert", "concert", "unplugged", "mtvunplugged", "acoustic",
        "collection", "completecollection", "definitivecollection", "ultimatecollection", "anthology",
        "singles", "singlescollection", "remixes", "remixed", "remastered", "gold", "platinum",
        "demos", "rarities", "bsides", "bsidesandrarities", "retrospective", "compilation", "hitsalbum",
    ]
    /// Folded beginnings that make a title generic whatever follows ("Best of Boston").
    /// (Not `gold` or `live`: "Golden Hour" and "Live Through This" tell acts apart.)
    static let genericPrefixes = ["greatesthits", "bestof", "verybestof", "essential", "anthology",
                                  "collection", "singles", "remixes", "unplugged", "mtvunplugged"]

    public static func verdict(_ candidate: ArtistPictureCandidate, name: String,
                               deviceAlbumTitles: [String]) -> ArtistPictureVerdict {
        guard PodBoxArtName.matches(candidate.name, name) else { return .noMatch }
        let ours = Set(deviceAlbumTitles.compactMap { telling($0, name: name) })
        return candidate.albumTitles.contains { telling($0, name: name).map(ours.contains) ?? false }
            ? .confident : .uncertain
    }

    /// The folded title without its trailing `(…)` and `[…]` groups.
    static func titleKey(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == ")" || last == "]" {
            guard let open = text.lastIndex(of: last == ")" ? "(" : "[") else { break }
            text = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PodBoxArtName.folded(text)
    }

    /// The title's key when it can tell this act from another of the same
    /// name: nil when empty, self-titled or generic.
    static func telling(_ title: String, name: String) -> String? {
        let key = titleKey(title)
        guard !key.isEmpty, !PodBoxArtName.matches(key, name), key != PodBoxArtName.folded(name),
              !genericTitles.contains(key), !genericPrefixes.contains(where: key.hasPrefix),
              !key.contains("greatesthits")
        else { return nil }
        return key
    }
}

/// What the finder concluded for one name.
public struct ArtistPictureFinding: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `prepared` is the exact JPEG to write. `candidate` is nil for the library's own picture.
        case found(prepared: Data, candidate: ArtistPictureCandidate?, source: ArtistPictureSourceID)
        /// Name matches nobody confirmed alone, at most five, for the owner to pick from.
        case uncertain([ArtistPictureCandidate])
        case notFound
        /// Something failed (no answer, a broken answer, a picture that would
        /// not download): nothing is known, so nothing may be stored and the
        /// name is asked again next time.
        case failed(String)

        /// Whether the outcome may be kept in the picture store. A failure
        /// never becomes "not found", which would be trusted for 30 days.
        public var isStorable: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    public let name: String, outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}

/// Finds pictures for names, one name at a time, and only ever returns a
/// picture for a sure match. Per name: the library's own picture if there
/// is one and it prepares; then each source in order. A source's
/// name-matching candidates are all scored (album titles fetched when
/// missing) before anything is accepted, and a picture is taken only when
/// exactly one of them is confident and its image prepares. Two or more
/// confident ones are an ambiguity: everything is held for the owner and no
/// later source is asked. Name matches not accepted come back as
/// `.uncertain` (at most five), nothing at all as `.notFound`.
///
/// Failures are never "not found": a broken answer or a picture that would
/// not download gives `.failed`, which is not stored. A failure to reach a
/// service at all (offline, a timeout, a 5xx) gives `.failed` for that name
/// and stops the run. A quota answer pauses the whole run, outside any
/// name's time budget, by each `quotaBackoff` delay in turn and asks again;
/// past the last delay the run stops, and that name is left for later.
///
/// Bounds: each name gets `perArtist` and the run `perRun`. A name not
/// reached or cut off by its own budget is absent from the result. The
/// finder never touches the store or a device.
public struct ArtistPictureFinder: Sendable {
    public typealias Request = (name: String, deviceAlbumTitles: [String], libraryPicture: URL?)

    public static let maximumUncertain = 5

    private let sources: [ArtistPictureSource]
    private let fetcher: ArtistPictureFetching
    private let perArtist: Duration
    private let perRun: Duration
    private let quotaBackoff: [Duration]

    public init(sources: [ArtistPictureSource], fetcher: ArtistPictureFetching,
                perArtist: Duration = .seconds(8), perRun: Duration = .seconds(120),
                quotaBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) {
        self.sources = sources
        self.fetcher = fetcher
        self.perArtist = perArtist
        self.perRun = perRun
        self.quotaBackoff = quotaBackoff
    }

    /// Serial. Stops early on a quota past its back-off, on a failure to
    /// reach a service, or when `perRun` elapses; names not reached are
    /// simply absent from the result.
    /// `progress` gets (names done, names asked for) after each name, for a
    /// run the owner watches.
    public func find(_ requests: [(name: String, deviceAlbumTitles: [String], libraryPicture: URL?)],
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async
        -> [ArtistPictureFinding] {
        let clock = ContinuousClock()
        let deadline = clock.now + perRun
        var findings: [ArtistPictureFinding] = []
        var pauses = quotaBackoff[...]
        var index = requests.startIndex
        while index < requests.endIndex {
            let request = requests[index]
            let remaining = deadline - clock.now
            guard remaining > .zero, !Task.isCancelled else { break }
            switch await bounded(min(perArtist, remaining), { try await self.findOne(request) }) {
            case .finished(let outcome):
                findings.append(ArtistPictureFinding(name: request.name, outcome: outcome))
                pauses = quotaBackoff[...]
                index += 1
                progress?(index, requests.count)
            case .unreachable(let reason):
                findings.append(ArtistPictureFinding(name: request.name, outcome: .failed(reason)))
                return findings
            case .quota:
                // Back off for the whole run, then ask for the same name again.
                guard let pause = pauses.popFirst(), clock.now + pause < deadline else { return findings }
                do { try await Task.sleep(for: pause) } catch { return findings }
            case .timedOut:
                index += 1
                progress?(index, requests.count)
            }
        }
        return findings
    }

    // MARK: - Private

    private enum Step: Sendable {
        case finished(ArtistPictureFinding.Outcome), quota, unreachable(String), timedOut
    }

    /// The run must stop: a quota, or a service that cannot be reached.
    private struct Stop: Error {
        let step: Step
    }

    /// Runs `work` against a timer; whichever ends first wins and the other is cancelled.
    private func bounded(_ budget: Duration,
                         _ work: @escaping @Sendable () async throws -> ArtistPictureFinding.Outcome) async -> Step {
        await withTaskGroup(of: Step.self) { group in
            group.addTask {
                do {
                    return .finished(try await work())
                } catch let stop as Stop {
                    return stop.step
                } catch {
                    return .timedOut // cancelled
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// Throws only `Stop` and cancellation.
    private func findOne(_ request: Request) async throws -> ArtistPictureFinding.Outcome {
        if let url = request.libraryPicture, let prepared = Self.preparedLibraryPicture(url) {
            return .found(prepared: prepared, candidate: nil, source: .libraryFolder)
        }
        var held: [ArtistPictureCandidate] = []
        var failure: String?
        sources: for source in sources {
            var scored: [(candidate: ArtistPictureCandidate, verdict: ArtistPictureVerdict)] = []
            do {
                for var candidate in try await source.candidates(for: request.name)
                where PodBoxArtName.matches(candidate.name, request.name) {
                    if candidate.albumTitles.isEmpty {
                        candidate.albumTitles = try await source.albumTitles(for: candidate)
                    }
                    scored.append((candidate, ArtistPictureMatcher.verdict(
                        candidate, name: request.name, deviceAlbumTitles: request.deviceAlbumTitles)))
                }
            } catch {
                try check(error)
                failure = failure ?? "\(source.id.rawValue) gave an answer CrateDigger could not read"
                continue
            }

            let confident = scored.filter { $0.verdict == .confident }.map(\.candidate)
            held += confident + scored.filter { $0.verdict != .confident }.map(\.candidate)
            switch confident.count {
            case 0:
                continue
            case 1:
                do {
                    if let prepared = ArtistPictureImage.prepare(try await fetcher.data(from: confident[0].imageURL)) {
                        return .found(prepared: prepared, candidate: confident[0], source: source.id)
                    }
                } catch {
                    try check(error)
                    failure = failure ?? "the picture from \(source.id.rawValue) did not download"
                }
            default:
                break sources // two acts both look right: the owner decides
            }
        }
        try Task.checkCancellation()
        if let failure { return .failed(failure) }
        return held.isEmpty ? .notFound : .uncertain(Array(held.prefix(Self.maximumUncertain)))
    }

    /// Rethrows what must stop the run (a quota, an unreachable service) or
    /// cancellation; anything else is one name's failure and returns.
    private func check(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        guard let source = ArtistPictureSourceError.reading(error) else { return }
        if source == .quota { throw Stop(step: .quota) }
        if source.stopsTheRun {
            let reason: String
            if case .transport(let detail) = source {
                reason = "could not reach the picture service: \(detail)"
            } else {
                reason = "the picture service is not answering"
            }
            throw Stop(step: .unreachable(reason))
        }
    }

    /// A picture file in the owner's library, read on the Mac when it is a
    /// plain file no bigger than a source image may be.
    static func preparedLibraryPicture(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size <= ArtistPictureImage.maximumSourceBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return ArtistPictureImage.prepare(data)
    }
}
