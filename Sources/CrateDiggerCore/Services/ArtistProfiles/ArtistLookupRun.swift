import Foundation

public enum ArtistLookupError: Error, Equatable, Sendable {
    /// Various Artists, Unknown Artist, or a name that folds to nothing:
    /// never looked up (`ArtistLookupScheduler.isLookedUp`).
    case notLookedUp(String)
    /// The picture finder could not finish for this artist (a service not
    /// answering, an answer it could not read). Nothing is known, so
    /// nothing may be stored.
    case pictureLookupFailed(String)
    /// The whole lookup of one artist ran past the background worker's
    /// limit for it (`ArtistLookupWorker`). A photo search that runs out of
    /// time is not this: the lookup returns what it found without a photo
    /// (`ArtistLookupResult.photoTimedOut`).
    case timedOut
}

/// What one lookup found for one artist. Only `identity` and `facts` are
/// the lookup's to write; the photo parts are offers that `apply` checks
/// against the profile as it is when they land.
public struct ArtistLookupResult: Sendable {
    public var identity: ArtistProfile.Identity
    public var facts: ArtistFacts?
    /// The photo to make the default: only when the profile had none it
    /// could keep. The bytes are the original, not the iPod's 400 px copy.
    public var defaultPhoto: (data: Data, source: ArtistPhoto.Source, sourceID: String?, credit: ArtistPictureCredit?)?
    /// Photos seen and not downloaded: references for the viewer.
    public var photoCandidates: [ArtistPictureRecord.HeldCandidate]
    /// The full-size original of the migrated default photo `hash`.
    public var replacementForMigrated: (hash: String, data: Data)?
    /// The identity the lookup started from. A result whose profile has
    /// moved on since (the owner picked a candidate or pasted an id while
    /// it ran) is stale, and `apply` writes none of it.
    public var basedOn: ArtistProfile.Identity
    /// The photo search ran out of time: the identity and facts are here,
    /// and nothing about a photo (no default, no candidates), so nothing
    /// about one is stored. The background worker then leaves this artist's
    /// photo alone for the rest of the session.
    public var photoTimedOut = false

    public init(identity: ArtistProfile.Identity, facts: ArtistFacts? = nil,
                defaultPhoto: (data: Data, source: ArtistPhoto.Source, sourceID: String?,
                               credit: ArtistPictureCredit?)? = nil,
                photoCandidates: [ArtistPictureRecord.HeldCandidate] = [],
                replacementForMigrated: (hash: String, data: Data)? = nil, basedOn: ArtistProfile.Identity = .unknown) {
        self.identity = identity
        self.facts = facts
        self.defaultPhoto = defaultPhoto
        self.photoCandidates = photoCandidates
        self.replacementForMigrated = replacementForMigrated
        self.basedOn = basedOn
    }
}

/// One artist's lookup (spec §4): who they are on MusicBrainz, their facts
/// and Wikipedia bio, and a default photo when the profile has none it may
/// keep. Never touches the store; `ArtistLookupResult.apply` does, and it
/// never changes anything the owner set.
///
/// Identity. A confirmed record is refreshed by its id, so a refresh never
/// unsettles an identity the owner picked on the page; a confirmed id that
/// MusicBrainz no longer has (a 404: deleted or merged away) comes back as
/// `.unknown`, with no facts and no photo work, so the next run searches
/// again. A rejected record ("None of these") is not looked up at all.
/// Anything else is searched by name, each name-equal candidate looked up
/// (at most five) for its release groups, and `ArtistIdentityMatcher`
/// decides. A confirmed identity gets its facts, its Wikidata id from the
/// winner's own lookup, and the bio plus its Wikipedia link.
///
/// Photos. None when the owner asked for no photo. When the default is a
/// migrated 400 px copy the owner did not pick, only its original is
/// fetched: from `replaceFromURL`, else, for a Deezer one, by its Deezer
/// id through `deezer`. When there is no default: the owner's library
/// folder picture, then (confirmed only) the artist's Wikidata image, then
/// the finder's own rule; under a confirmed identity the finder's Deezer
/// pick must also fold equal to the confirmed artist's name, and its
/// Commons pick must be that MusicBrainz artist's own. Sources the
/// owner removed (`rejectedPhotoSources`) are skipped. Only the chosen
/// photo is downloaded, once (the finder's own download of it is reused);
/// the rest come back as references.
///
/// Errors propagate and nothing is stored: a transport error, 5xx or 429
/// from MusicBrainz, Wikidata or Wikipedia as `ArtistPictureSourceError`,
/// a finder failure as `ArtistLookupError`. A picture that fails to
/// download for a reason that does not stop the run (a 404, a broken
/// image) is simply not taken.
///
/// Commons. The finder's own Commons source is never asked: it searches
/// MusicBrainz a second time and follows each namesake's Wikidata item,
/// which for a common name ("Low", "Genesis") ran past the time a photo
/// gets. Under a confirmed identity it is left out altogether (the
/// confirmed artist's own image is already known, or there is none, and
/// any other Commons pick is a namesake's). Under any other identity the
/// Commons candidates are built from the identity search's own lookups,
/// which already hold each act's Wikidata id and albums.
///
/// A photo search that runs out of time is "no photo this time": the
/// result keeps the identity and facts and says `photoTimedOut`.
///
/// Requests: every MusicBrainz request waits in `lane`, the finder's
/// sources' included (`findSingle(_:lane:)`), so a background run never
/// makes a lookup the owner started wait. The run's own Wikidata, Commons
/// and image requests are kept `spacing` apart. Keep one long-lived run
/// (and one `info` client) so the spacing holds across artists.
public struct ArtistLookupRun: Sendable {
    /// Name-equal search results looked up for their release groups.
    static let detailsLooked = ArtistIdentityMatcher.maximumUncertain

    private let info: ArtistInfoFetching
    private let pictures: ArtistPictureFinder
    private let fetcher: ArtistPictureFetching
    private let deezer: ArtistPictureSource?
    private let preferredLanguages: [String]
    private let spacer: RequestSpacer

    public init(info: ArtistInfoFetching, pictures: ArtistPictureFinder, fetcher: ArtistPictureFetching,
                deezer: ArtistPictureSource? = nil, preferredLanguages: [String] = Locale.preferredLanguages,
                spacing: Duration = .seconds(1)) {
        self.info = info
        self.pictures = pictures
        self.fetcher = fetcher
        self.deezer = deezer
        self.preferredLanguages = preferredLanguages
        spacer = RequestSpacer(spacing: spacing)
    }

    /// One artist: identity, facts, bio, and a default photo when the
    /// profile has none it may keep. With `findsPhoto` false (the worker,
    /// for an artist whose photo search ran out of time earlier this
    /// session) no photo work is done at all.
    public func lookUp(name: String, libraryAlbumTitles: [String], libraryPicture: URL?,
                       existing: ArtistProfile?, lane: MusicBrainzGate.Lane, now: Date,
                       findsPhoto: Bool = true) async throws -> ArtistLookupResult {
        guard ArtistLookupScheduler.isLookedUp(name) else { throw ArtistLookupError.notLookedUp(name) }
        let basedOn = existing?.identity ?? .unknown
        guard let found = try await identify(name: name, libraryAlbumTitles: libraryAlbumTitles, existing: existing,
                                             lane: lane) else {
            return ArtistLookupResult(identity: .unknown, basedOn: basedOn)
        }
        var result = ArtistLookupResult(identity: found.identity, facts: found.facts, basedOn: basedOn)
        guard findsPhoto else { return result }

        guard let existing else {
            try await choosePhoto(into: &result, found: found, name: name, libraryAlbumTitles: libraryAlbumTitles,
                                  libraryPicture: libraryPicture, excluded: [], lane: lane)
            return result
        }
        guard !existing.noPhoto else { return result }
        if let current = existing.photos.first(where: { $0.hash == existing.defaultPhoto }) {
            if !existing.defaultPickedByOwner, current.source == .migrated,
               let original = try await original(of: current, name: name) {
                result.replacementForMigrated = (current.hash, original)
            }
            return result
        }
        let excluded = Set(existing.rejectedPhotoSources).union(existing.photos.compactMap(\.rejectionKey))
        try await choosePhoto(into: &result, found: found, name: name, libraryAlbumTitles: libraryAlbumTitles,
                              libraryPicture: libraryPicture, excluded: excluded, lane: lane)
        return result
    }

    /// Runs `work`, cancelling it and throwing `ArtistLookupError.timedOut`
    /// when it is still running after `limit`. Cancellation passes through.
    public static func bounded<T: Sendable>(_ limit: Duration,
                                            _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                try Task.checkCancellation()
                throw ArtistLookupError.timedOut
            }
            return value
        }
    }

    // MARK: - Identity

    private struct Identified {
        var identity: ArtistProfile.Identity
        var facts: ArtistFacts?
        var musicBrainzID: String?
        var wikidataID: String?
        /// The confirmed artist's name on MusicBrainz; nil unless confirmed.
        var confirmedName: String?
        /// The name-equal acts the search looked up, for the photo's Commons
        /// candidates; empty for a refresh by id.
        var acts: [Act] = []
    }

    /// One act the identity search looked up: its MusicBrainz id and name,
    /// its Wikidata item, and its albums.
    struct Act: Sendable {
        var musicBrainzID: String
        var name: String
        var wikidataID: String?
        var albumTitles: [String]
    }

    /// nil when the confirmed id is gone from MusicBrainz: the identity is lost.
    private func identify(name: String, libraryAlbumTitles: [String], existing: ArtistProfile?,
                          lane: MusicBrainzGate.Lane) async throws -> Identified? {
        let rejectedIDs = existing?.rejectedMusicBrainzIDs ?? []
        var found: Identified
        switch existing?.identity {
        case .rejected?:
            return Identified(identity: .rejected)
        case let .confirmed(id, _)? where !rejectedIDs.contains(id):
            let detail: (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String])
            do {
                detail = try await info.detail(musicBrainzID: id, lane: lane)
            } catch ArtistPictureSourceError.http(404) {
                return nil
            }
            found = Identified(identity: .confirmed(musicBrainzID: id, wikidataID: detail.wikidataID),
                               facts: detail.facts, musicBrainzID: id, wikidataID: detail.wikidataID,
                               confirmedName: existing?.displayName ?? name)
        default:
            found = try await search(name: name, libraryAlbumTitles: libraryAlbumTitles, rejectedIDs: rejectedIDs,
                                     lane: lane)
        }
        if let wikidataID = found.wikidataID,
           let bio = try await info.bio(wikidataID: wikidataID, preferredLanguages: preferredLanguages) {
            var facts = found.facts ?? ArtistFacts()
            facts.bio = bio.extract
            facts.bioSourceURL = bio.pageURL
            facts.links = (facts.links ?? []) + [ArtistLink(kind: .wikipedia, url: bio.pageURL)]
            found.facts = facts
        }
        return found
    }

    private func search(name: String, libraryAlbumTitles: [String], rejectedIDs: [String],
                        lane: MusicBrainzGate.Lane) async throws -> Identified {
        // Rejected ones are looked up too: the matcher counts them, so a
        // rejected act that fits the library keeps the others uncertain.
        let named = try await info.candidates(for: name, lane: lane)
            .filter { PodBoxArtName.matches($0.name, name) }
            .prefix(Self.detailsLooked)
        var details: [String: (facts: ArtistFacts, wikidataID: String?)] = [:]
        var scored: [(ArtistIdentityCandidate, releaseGroupTitles: [String])] = []
        var acts: [Act] = []
        for candidate in named {
            do {
                let detail = try await info.detail(musicBrainzID: candidate.musicBrainzID, lane: lane)
                details[candidate.musicBrainzID] = (detail.facts, detail.wikidataID)
                scored.append((candidate, detail.releaseGroupTitles))
                if !rejectedIDs.contains(candidate.musicBrainzID) {
                    acts.append(Act(musicBrainzID: candidate.musicBrainzID, name: candidate.name,
                                    wikidataID: detail.wikidataID, albumTitles: detail.releaseGroupTitles))
                }
            } catch ArtistPictureSourceError.http(404) {
                continue // in the search index, gone from the database
            }
        }
        let identity = ArtistIdentityMatcher.decide(name: name, libraryAlbumTitles: libraryAlbumTitles,
                                                    candidates: scored, rejected: rejectedIDs)
        guard case .confirmed(let id, _) = identity, let detail = details[id] else {
            return Identified(identity: identity, acts: acts)
        }
        return Identified(identity: .confirmed(musicBrainzID: id, wikidataID: detail.wikidataID),
                          facts: detail.facts, musicBrainzID: id, wikidataID: detail.wikidataID,
                          confirmedName: named.first { $0.musicBrainzID == id }?.name ?? name)
    }

    // MARK: - Photos

    /// The default photo for a profile that has none, and the references
    /// seen on the way. Stops at the first photo taken.
    private func choosePhoto(into result: inout ArtistLookupResult, found: Identified, name: String,
                             libraryAlbumTitles: [String], libraryPicture: URL?, excluded: Set<String>,
                             lane: MusicBrainzGate.Lane) async throws {
        if let url = libraryPicture, !excluded.contains(Self.libraryKey(url)), let data = Self.libraryPictureData(url) {
            result.defaultPhoto = (data, .library, url.path, nil)
            return
        }

        if let id = found.musicBrainzID, let wikidataID = found.wikidataID,
           let portrait = try await wikidataPortrait(wikidataID: wikidataID, musicBrainzID: id, name: name),
           !excluded.contains(Self.rejectionKey(ArtistPictureRecord.HeldCandidate(portrait))),
           let data = try await download(portrait.imageURL) {
            result.defaultPhoto = (data, .commons, id, portrait.credit)
            return
        }

        // Never the finder's own Commons source (see the type's notes).
        var sources = pictures.sources.filter { $0.id != .commons }
        if found.confirmedName == nil, !found.acts.isEmpty {
            sources.append(LookupCommonsSource(acts: found.acts, run: self))
        }
        let finding: ArtistPictureFinding
        switch await pictures.asking(sources).findSingle(
            (name: name, deviceAlbumTitles: libraryAlbumTitles, libraryPicture: nil), lane: lane) {
        case .finding(let found):
            finding = found
        case .timedOut:
            // No photo this time: the identity and facts still land.
            try Task.checkCancellation()
            result.photoTimedOut = true
            return
        case .quota:
            try Task.checkCancellation()
            throw ArtistPictureSourceError.quota
        }
        try Task.checkCancellation()
        var held: [ArtistPictureRecord.HeldCandidate] = []
        switch finding.outcome {
        case .found(_, let candidate?, let source):
            let reference = ArtistPictureRecord.HeldCandidate(candidate)
            let accepted = Self.photoSource(source) != nil
                && !excluded.contains(Self.rejectionKey(reference))
                && Self.fits(candidate, source: source, found)
            // The finder already downloaded the original to prepare it: taken
            // from the finding, never fetched a second time.
            let original: Data?
            if accepted, let kept = finding.original, finding.originalURL == candidate.imageURL {
                original = kept
            } else if accepted {
                original = try await download(candidate.imageURL)
            } else {
                original = nil
            }
            if accepted, let photoSource = Self.photoSource(source), let data = original {
                result.defaultPhoto = (data, photoSource, candidate.sourceID, candidate.credit)
            } else {
                held = [reference]
            }
        case .found(_, nil, _), .notFound:
            break
        case .uncertain(let candidates):
            held = candidates.map(ArtistPictureRecord.HeldCandidate.init)
        case .failed(let reason):
            throw ArtistLookupError.pictureLookupFailed(reason)
        }
        var seen = excluded
        result.photoCandidates = held.filter { seen.insert(Self.rejectionKey($0)).inserted }
    }

    /// Whether the finder's pick may be taken under the identity found. Any
    /// pick when the identity is not confirmed (the finder's rule alone, as
    /// the iPod has always had it). Under a confirmed identity, a Commons
    /// pick only when it is that very MusicBrainz artist's picture (a
    /// namesake's has the same name and another id), and any other only
    /// when its name folds equal to the confirmed artist's.
    private static func fits(_ candidate: ArtistPictureCandidate, source: ArtistPictureSourceID,
                             _ found: Identified) -> Bool {
        guard let id = found.musicBrainzID, let confirmedName = found.confirmedName else { return true }
        if source == .commons { return candidate.sourceID == id }
        return PodBoxArtName.folded(candidate.name) == PodBoxArtName.folded(confirmedName)
    }

    /// The full-size original of a migrated photo, or nil when it cannot be
    /// found again (the photo then stays as it is).
    private func original(of photo: ArtistPhoto, name: String) async throws -> Data? {
        if let url = photo.replaceFromURL { return try await download(url) }
        let prefix = ArtistPhoto.Source.deezer.rawValue + ":"
        guard let deezer, let sourceID = photo.sourceID, sourceID.hasPrefix(prefix) else { return nil }
        let id = String(sourceID.dropFirst(prefix.count))
        let candidates: [ArtistPictureCandidate]
        do {
            candidates = try await deezer.candidates(for: name)
        } catch {
            try Self.rethrowIfStopping(error)
            return nil
        }
        guard let match = candidates.first(where: { $0.sourceID == id }) else { return nil }
        return try await download(match.imageURL)
    }

    /// The image (P18) of an artist's Wikidata item, credited as Commons
    /// states it, asked for at the size fetched photos are kept at.
    func wikidataPortrait(wikidataID: String, musicBrainzID: String,
                                  name: String) async throws -> ArtistPictureCandidate? {
        guard CommonsArtistParser.isEntityID(wikidataID) else { return nil }
        try await spacer.wait()
        let entity: Data
        do {
            entity = try await fetcher.data(from: CommonsArtistSource.entityURL(id: wikidataID))
        } catch ArtistPictureSourceError.http(404) {
            return nil
        }
        guard let file = try CommonsArtistParser.imageFileName(fromEntity: entity, id: wikidataID) else { return nil }
        let credit = try await commonsCredit(for: file)
        return ArtistPictureCandidate(name: name, source: .commons, sourceID: musicBrainzID,
                                      imageURL: CommonsArtistParser.imageURL(fileName: file,
                                                                             width: ArtistPhotoImage.fetchedLongSide),
                                      credit: credit)
    }

    /// The Commons file's credit, as the Commons source reads it: the file
    /// name alone when the answer is missing or unreadable; a failure that
    /// stops the run is thrown.
    private func commonsCredit(for fileName: String) async throws -> ArtistPictureCredit {
        let bare = ArtistPictureCredit(fileName: fileName)
        try await spacer.wait()
        let data: Data
        do {
            data = try await fetcher.data(from: CommonsArtistSource.imageInfoURL(fileName: fileName))
        } catch {
            try Self.rethrowIfStopping(error)
            return bare
        }
        return (try? CommonsArtistParser.credit(fromImageInfo: data, fileName: fileName)) ?? bare
    }

    /// The bytes at `url` when they are a picture the iPod could take too;
    /// nil for one that will not download for a reason of its own.
    private func download(_ url: URL) async throws -> Data? {
        try await spacer.wait()
        do {
            let data = try await fetcher.data(from: url)
            return ArtistPictureImage.prepare(data) == nil ? nil : data
        } catch {
            try Self.rethrowIfStopping(error)
            return nil
        }
    }

    /// Rethrows cancellation, a quota, anything that stops the run
    /// (`stopsTheRun`) and any error that is not a source's.
    static func rethrowIfStopping(_ error: Error) throws {
        if error is CancellationError { throw error }
        guard let source = ArtistPictureSourceError.reading(error) else { throw error }
        if source == .quota || source.stopsTheRun { throw source }
    }

    /// A picture file beside the owner's music, read whole when it is a
    /// plain file no bigger than a source image may be and it prepares.
    static func libraryPictureData(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size <= ArtistPictureImage.maximumSourceBytes,
              let data = try? Data(contentsOf: url), ArtistPictureImage.prepare(data) != nil
        else { return nil }
        return data
    }

    // MARK: - Source names

    /// The profile photo source for a finder source; nil for one a profile
    /// does not keep photos from.
    static func photoSource(_ source: ArtistPictureSourceID) -> ArtistPhoto.Source? {
        switch source {
        case .deezer: return .deezer
        case .commons: return .commons
        case .libraryFolder: return .library
        case .userFile, .fanartTV, .discogs, .theAudioDB: return nil
        }
    }

    /// `<source>:<id>` in the profile's own source names: what
    /// `ArtistPhoto.rejectionKey` gives for the photo this would become.
    static func rejectionKey(_ candidate: ArtistPictureRecord.HeldCandidate) -> String {
        "\(photoSource(candidate.source)?.rawValue ?? candidate.source.rawValue):\(candidate.sourceID)"
    }

    /// A library folder picture is known by its path (which never leaves the Mac).
    static func libraryKey(_ url: URL) -> String {
        "\(ArtistPhoto.Source.library.rawValue):\(url.path)"
    }
}

// MARK: - Commons from the identity search

/// Commons candidates for the acts the identity search already looked up:
/// each act's Wikidata image (P18), with that act's albums for the finder's
/// match rule, so no second MusicBrainz search is made. An act with no
/// Wikidata item, or an item with no image, gives no candidate.
struct LookupCommonsSource: ArtistPictureSource {
    var id: ArtistPictureSourceID { .commons }
    let acts: [ArtistLookupRun.Act]
    let run: ArtistLookupRun

    func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
        var candidates: [ArtistPictureCandidate] = []
        for act in acts {
            guard let wikidataID = act.wikidataID,
                  var portrait = try await run.wikidataPortrait(wikidataID: wikidataID,
                                                                musicBrainzID: act.musicBrainzID, name: act.name)
            else { continue }
            portrait.albumTitles = act.albumTitles
            candidates.append(portrait)
        }
        return candidates
    }

    func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] {
        candidate.albumTitles
    }
}

// MARK: - Applying a result

extension ArtistLookupResult {
    /// Writes this result into `store` for `name`, checked against the
    /// profile as it is now, since the owner may have acted while the
    /// lookup ran. Every write is a compare-and-apply under the store's
    /// lock, so nothing the owner does in between can be overwritten.
    ///
    /// The identity and fetched facts land only while the identity is still
    /// `basedOn` (a stale result, after the owner picked a candidate, pasted
    /// an id or pressed Look Up Again, writes nothing), and only where
    /// `applyFetched` allows (not over "None of these", not a confirmed id
    /// the owner rejected). Each later write lands only while the identity
    /// is still the one just written: the default photo while there is no
    /// default, no "no photo" and no rejection of its source; the migrated
    /// original, in the migrated photo's place, while that photo is still
    /// the default and not the owner's pick; candidates when new, not
    /// rejected, and not under "no photo". Owner facts, owner photos, an
    /// owner-picked default, `noPhoto`, `notOnIPod` and the rejected ids are
    /// never changed. Does not save. Store I/O and image work: call it off
    /// the main actor, after `refuseWhileLibraryDisconnected`. Returns
    /// whether the identity and facts were applied.
    @discardableResult
    public func apply(to store: ArtistProfileStore, name: String, at date: Date) throws -> Bool {
        guard let written = store.applyFetched(name: name, facts: facts, identity: identity, at: date,
                                               ifIdentityIs: basedOn) else { return false }

        if let photo = defaultPhoto {
            let rejection = Self.key(photo.source, photo.sourceID)
            try Self.keeping {
                try store.addPhoto(name: name, data: photo.data, source: photo.source, sourceID: photo.sourceID,
                                   credit: photo.credit) { before, _, _ in
                    guard let before, before.identity == written, !before.noPhoto,
                          !before.photos.contains(where: { $0.hash == before.defaultPhoto }) else { return false }
                    return rejection.map(before.rejectedPhotoSources.contains) != true
                }
            }
        }

        if let replacement = replacementForMigrated,
           let old = store.profile(forName: name)?.photos.first(where: { $0.hash == replacement.hash }) {
            try replace(old, with: replacement.data, in: store, name: name, identity: written)
        }

        let candidates = photoCandidates
        if !candidates.isEmpty {
            store.update(name: name, ifIdentityIs: written) { profile in
                guard !profile.noPhoto else { return }
                var known = Set(profile.rejectedPhotoSources).union(profile.photos.compactMap(\.rejectionKey))
                known.formUnion(profile.photoCandidates.map(ArtistLookupRun.rejectionKey))
                for candidate in candidates where known.insert(ArtistLookupRun.rejectionKey(candidate)).inserted {
                    profile.photoCandidates.append(candidate)
                }
            }
        }
        return true
    }

    private static func mayReplace(_ hash: String, in profile: ArtistProfile) -> Bool {
        !profile.noPhoto && !profile.defaultPickedByOwner && profile.defaultPhoto == hash
            && profile.photos.first(where: { $0.hash == hash })?.source == .migrated
    }

    /// Runs a photo write; bytes the store will not keep are no photo.
    private static func keeping(_ write: () throws -> ArtistPhoto?) throws {
        do {
            _ = try write()
        } catch ArtistProfileStoreError.unreadablePhoto, ArtistProfileStoreError.photoTooLarge {
            // Not a picture the store keeps: the profile goes without.
        }
    }

    /// The original takes the migrated photo's place and its role as
    /// default, under the source the migrated id names (`deezer:42` becomes
    /// Deezer's `42`), in one write. When the profile already held the
    /// original's bytes, that entry moves into the migrated photo's place;
    /// nothing else moves. The old entry is dropped without being remembered
    /// as removed, so its source stays welcome; its file goes at the next
    /// save. Nothing is written unless, as it lands, the identity is still
    /// `identity` and the migrated photo is still the default, not the
    /// owner's pick, under no "no photo".
    private func replace(_ old: ArtistPhoto, with data: Data, in store: ArtistProfileStore, name: String,
                         identity: ArtistProfile.Identity) throws {
        var source = ArtistPhoto.Source.migrated
        var sourceID = old.sourceID
        if let parts = old.sourceID?.split(separator: ":", maxSplits: 1), parts.count == 2,
           let named = ArtistPhoto.Source(rawValue: String(parts[0])), named != .owner, named != .migrated {
            source = named
            sourceID = String(parts[1])
        }
        try Self.keeping {
            try store.addPhoto(name: name, data: data, source: source, sourceID: sourceID,
                               credit: old.credit) { before, after, new in
                guard let before, before.identity == identity, new.hash != old.hash,
                      Self.mayReplace(old.hash, in: before) else { return false }
                // The original's entry out first, then the migrated photo
                // found again: removing an entry before it moves it down by one.
                after.photos.removeAll { $0.hash == new.hash }
                guard let at = after.photos.firstIndex(where: { $0.hash == old.hash }) else { return false }
                after.photos[at] = new
                after.defaultPhoto = new.hash
                return true
            }
        }
    }

    private static func key(_ source: ArtistPhoto.Source, _ sourceID: String?) -> String? {
        ArtistPhoto(hash: "", source: source, sourceID: sourceID, pixelWidth: 0, pixelHeight: 0,
                    added: .distantPast).rejectionKey
    }
}

// MARK: - A lookup the owner asked for

extension ArtistProfileStore {
    /// Look Up Again, or the lookup the page runs after the owner settles an
    /// identity: with `resetFirst` the identity goes back to `.unknown`
    /// first, so even "None of these" is asked again; then `lookUp` is given
    /// the profile as it is now and its result applied and saved.
    ///
    /// When anything throws (offline, a service down), the identity the
    /// reset replaced comes back, as long as nothing has set another one
    /// since, and the file is left as the owner had it: a failed Look Up
    /// Again never loses the candidates or the owner's "None of these".
    /// Store I/O: call it off the main actor.
    public func lookUpAgain(name: String, resetFirst: Bool, at date: Date,
                            _ lookUp: (ArtistProfile?) async throws -> ArtistLookupResult) async throws {
        let before = profile(forName: name)?.identity ?? .unknown
        if resetFirst { resetIdentity(name: name) }
        do {
            let result = try await lookUp(profile(forName: name))
            try result.apply(to: self, name: name, at: date)
            try save()
        } catch {
            if resetFirst, before != .unknown {
                update(name: name, ifIdentityIs: .unknown) { $0.identity = before }
            }
            // Whatever did land (a result applied before a photo failed) is kept.
            try? save()
            throw error
        }
    }
}

// MARK: - The owner picking a found photo

extension ArtistProfileStore {
    /// The owner picked one of the photos the lookup found but did not
    /// download (the Edit sheet, the viewer): its downloaded `data` becomes
    /// one of the profile's photos, stored as a fetched photo (1,600 px),
    /// under the candidate's own source, id and credit, and the reference
    /// goes from `photoCandidates`. The default stays where it is (the
    /// owner makes this one the default separately), unless the profile has
    /// none. Throws as `addPhoto` does, and for a candidate from a source
    /// profiles keep no photos of. Does not save; store I/O and image work,
    /// so off the main actor.
    @discardableResult
    public func addCandidatePhoto(name: String, candidate: ArtistPictureRecord.HeldCandidate,
                                  data: Data) throws -> ArtistPhoto {
        guard let source = ArtistLookupRun.photoSource(candidate.source) else {
            throw ArtistProfileStoreError.unreadablePhoto
        }
        let key = ArtistLookupRun.rejectionKey(candidate)
        // A decision that always keeps the photo never refuses: nil cannot come back.
        return try addPhoto(name: name, data: data, source: source, sourceID: candidate.sourceID,
                            credit: candidate.credit) { _, after, _ in
            after.photoCandidates.removeAll { ArtistLookupRun.rejectionKey($0) == key }
            return true
        }!
    }
}
