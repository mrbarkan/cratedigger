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
/// `PodBoxArtName.folded` (case, accents and punctuation ignored). A title
/// that folds to nothing never matches. Anything else is `uncertain`.
public enum ArtistPictureMatcher {
    public static func verdict(_ candidate: ArtistPictureCandidate, name: String,
                               deviceAlbumTitles: [String]) -> ArtistPictureVerdict {
        guard PodBoxArtName.matches(candidate.name, name) else { return .noMatch }
        let ours = Set(deviceAlbumTitles.map(titleKey).filter { !$0.isEmpty })
        return candidate.albumTitles.contains { ours.contains(titleKey($0)) } ? .confident : .uncertain
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
}

/// What the finder concluded for one name.
public struct ArtistPictureFinding: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `prepared` is the exact JPEG to write. `candidate` is nil for the library's own picture.
        case found(prepared: Data, candidate: ArtistPictureCandidate?, source: ArtistPictureSourceID)
        /// Name matches nobody confirmed, at most five, for the owner to pick from.
        case uncertain([ArtistPictureCandidate])
        case notFound
    }

    public let name: String, outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}

/// Finds pictures for names, one name at a time, and only ever returns a
/// picture for a confident match. Per name: the library's own picture if
/// there is one and it prepares; then each source in order, its
/// name-matching candidates in turn (album titles fetched when missing),
/// the first confident one whose image prepares. Name matches that no album
/// confirms come back as `.uncertain` (at most five), nothing at all as
/// `.notFound`. A source that fails for a name other than by quota is done
/// for that name, so one bad answer is not a whole run's failure.
///
/// Bounds: each name gets `perArtist` and the run `perRun`. A quota answer
/// stops the run. A name not reached, cut off by its own budget, or hit by
/// the quota is simply absent from the result, so it is tried again later
/// rather than recorded as having no picture. The finder never touches the
/// store or a device.
public struct ArtistPictureFinder: Sendable {
    public typealias Request = (name: String, deviceAlbumTitles: [String], libraryPicture: URL?)

    public static let maximumUncertain = 5

    private let sources: [ArtistPictureSource]
    private let fetcher: ArtistPictureFetching
    private let perArtist: Duration
    private let perRun: Duration

    public init(sources: [ArtistPictureSource], fetcher: ArtistPictureFetching,
                perArtist: Duration = .seconds(8), perRun: Duration = .seconds(120)) {
        self.sources = sources
        self.fetcher = fetcher
        self.perArtist = perArtist
        self.perRun = perRun
    }

    /// Serial. Stops early on `.quota` or when `perRun` elapses; names not
    /// reached are simply absent from the result.
    public func find(_ requests: [(name: String, deviceAlbumTitles: [String], libraryPicture: URL?)]) async
        -> [ArtistPictureFinding] {
        let clock = ContinuousClock()
        let deadline = clock.now + perRun
        var findings: [ArtistPictureFinding] = []
        for request in requests {
            let remaining = deadline - clock.now
            guard remaining > .zero, !Task.isCancelled else { break }
            switch await bounded(min(perArtist, remaining), { try await self.findOne(request) }) {
            case .finished(let outcome): findings.append(ArtistPictureFinding(name: request.name, outcome: outcome))
            case .quota: return findings
            case .timedOut: continue
            }
        }
        return findings
    }

    // MARK: - Private

    private enum Step: Sendable {
        case finished(ArtistPictureFinding.Outcome), quota, timedOut
    }

    /// Runs `work` against a timer; whichever ends first wins and the other is cancelled.
    private func bounded(_ budget: Duration,
                         _ work: @escaping @Sendable () async throws -> ArtistPictureFinding.Outcome) async -> Step {
        await withTaskGroup(of: Step.self) { group in
            group.addTask {
                do {
                    return .finished(try await work())
                } catch ArtistPictureSourceError.quota {
                    return .quota
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

    /// Throws only `.quota` and cancellation.
    private func findOne(_ request: Request) async throws -> ArtistPictureFinding.Outcome {
        if let url = request.libraryPicture, let prepared = Self.preparedLibraryPicture(url) {
            return .found(prepared: prepared, candidate: nil, source: .libraryFolder)
        }
        var unsure: [ArtistPictureCandidate] = []
        for source in sources {
            do {
                for var candidate in try await source.candidates(for: request.name)
                where PodBoxArtName.matches(candidate.name, request.name) {
                    if candidate.albumTitles.isEmpty {
                        candidate.albumTitles = try await source.albumTitles(for: candidate)
                    }
                    guard ArtistPictureMatcher.verdict(candidate, name: request.name,
                                                       deviceAlbumTitles: request.deviceAlbumTitles) == .confident
                    else {
                        unsure.append(candidate)
                        continue
                    }
                    if let prepared = try await preparedImage(candidate.imageURL) {
                        return .found(prepared: prepared, candidate: candidate, source: source.id)
                    }
                }
            } catch let error as ArtistPictureSourceError where error == .quota {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                continue // this source is done for this name
            }
        }
        try Task.checkCancellation()
        return unsure.isEmpty ? .notFound : .uncertain(Array(unsure.prefix(Self.maximumUncertain)))
    }

    /// The picture at `url`, prepared, or nil when it cannot be fetched or
    /// used (the next candidate is tried). Throws only cancellation.
    private func preparedImage(_ url: URL) async throws -> Data? {
        do {
            return ArtistPictureImage.prepare(try await fetcher.data(from: url))
        } catch {
            try Task.checkCancellation()
            return nil
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
