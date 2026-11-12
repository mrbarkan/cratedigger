import Foundation

public enum ArtistLookupError: Error, Equatable, Sendable {
    /// Various Artists, Unknown Artist, or a name that folds to nothing:
    /// never looked up (`ArtistLookupScheduler.isLookedUp`).
    case notLookedUp(String)
    /// The picture finder could not finish for this artist (a service not
    /// answering, an answer it could not read). Nothing is known, so
    /// nothing may be stored.
    case pictureLookupFailed(String)
    /// The picture finder ran out of time for this artist.
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

    public init(identity: ArtistProfile.Identity, facts: ArtistFacts? = nil,
                defaultPhoto: (data: Data, source: ArtistPhoto.Source, sourceID: String?,
                               credit: ArtistPictureCredit?)? = nil,
                photoCandidates: [ArtistPictureRecord.HeldCandidate] = [],
                replacementForMigrated: (hash: String, data: Data)? = nil) {
        self.identity = identity
        self.facts = facts
        self.defaultPhoto = defaultPhoto
        self.photoCandidates = photoCandidates
        self.replacementForMigrated = replacementForMigrated
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
/// pick must also fold equal to the confirmed artist's name. Sources the
/// owner removed (`rejectedPhotoSources`) are skipped. Only the chosen
/// photo is downloaded; the rest come back as references.
///
/// Errors propagate and nothing is stored: a transport error, 5xx or 429
/// from MusicBrainz, Wikidata or Wikipedia as `ArtistPictureSourceError`,
/// a finder failure as `ArtistLookupError`. A picture that fails to
/// download for a reason that does not stop the run (a 404, a broken
/// image) is simply not taken.
///
/// Requests: MusicBrainz waits in `lane`; the run's own Wikidata, Commons
/// and image requests are kept `spacing` apart. Keep one long-lived run
/// (and one `info` client) so the spacing holds across artists. The
/// finder's sources choose their own MusicBrainz lane: give a background
/// run a finder without `CommonsArtistSource` (which waits in the
/// foreground); a confirmed artist's Commons picture comes through
/// Wikidata here instead.
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

    /// One artist: identity, facts, bio, and a default photo when the profile has none it may keep.
    public func lookUp(name: String, libraryAlbumTitles: [String], libraryPicture: URL?,
                       existing: ArtistProfile?, lane: MusicBrainzGate.Lane, now: Date) async throws
        -> ArtistLookupResult {
        guard ArtistLookupScheduler.isLookedUp(name) else { throw ArtistLookupError.notLookedUp(name) }
        guard let found = try await identify(name: name, libraryAlbumTitles: libraryAlbumTitles, existing: existing,
                                             lane: lane) else {
            return ArtistLookupResult(identity: .unknown)
        }
        var result = ArtistLookupResult(identity: found.identity, facts: found.facts)

        guard let existing else {
            try await choosePhoto(into: &result, found: found, name: name, libraryAlbumTitles: libraryAlbumTitles,
                                  libraryPicture: libraryPicture, excluded: [])
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
                              libraryPicture: libraryPicture, excluded: excluded)
        return result
    }

    // MARK: - Identity

    private struct Identified {
        var identity: ArtistProfile.Identity
        var facts: ArtistFacts?
        var musicBrainzID: String?
        var wikidataID: String?
        /// The confirmed artist's name on MusicBrainz; nil unless confirmed.
        var confirmedName: String?
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
        for candidate in named {
            do {
                let detail = try await info.detail(musicBrainzID: candidate.musicBrainzID, lane: lane)
                details[candidate.musicBrainzID] = (detail.facts, detail.wikidataID)
                scored.append((candidate, detail.releaseGroupTitles))
            } catch ArtistPictureSourceError.http(404) {
                continue // in the search index, gone from the database
            }
        }
        let identity = ArtistIdentityMatcher.decide(name: name, libraryAlbumTitles: libraryAlbumTitles,
                                                    candidates: scored, rejected: rejectedIDs)
        guard case .confirmed(let id, _) = identity, let detail = details[id] else {
            return Identified(identity: identity)
        }
        return Identified(identity: .confirmed(musicBrainzID: id, wikidataID: detail.wikidataID),
                          facts: detail.facts, musicBrainzID: id, wikidataID: detail.wikidataID,
                          confirmedName: named.first { $0.musicBrainzID == id }?.name ?? name)
    }

    // MARK: - Photos

    /// The default photo for a profile that has none, and the references
    /// seen on the way. Stops at the first photo taken.
    private func choosePhoto(into result: inout ArtistLookupResult, found: Identified, name: String,
                             libraryAlbumTitles: [String], libraryPicture: URL?, excluded: Set<String>) async throws {
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

        let findings = await pictures.find([(name: name, deviceAlbumTitles: libraryAlbumTitles, libraryPicture: nil)])
        try Task.checkCancellation()
        guard let finding = findings.first else { throw ArtistLookupError.timedOut }
        var held: [ArtistPictureRecord.HeldCandidate] = []
        switch finding.outcome {
        case .found(_, let candidate?, let source):
            let reference = ArtistPictureRecord.HeldCandidate(candidate)
            let accepted = Self.photoSource(source) != nil
                && !excluded.contains(Self.rejectionKey(reference))
                && found.confirmedName.map { PodBoxArtName.folded(candidate.name) == PodBoxArtName.folded($0) } ?? true
            if accepted, let photoSource = Self.photoSource(source), let data = try await download(candidate.imageURL) {
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

    /// The image (P18) of a confirmed artist's Wikidata item, credited as
    /// Commons states it, asked for at the size fetched photos are kept at.
    private func wikidataPortrait(wikidataID: String, musicBrainzID: String,
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

// MARK: - Applying a result

extension ArtistLookupResult {
    /// Writes this result into `store` for `name`, checked against the
    /// profile as it is now, since the owner may have acted while the
    /// lookup ran. The identity and fetched facts go through
    /// `applyFetched`; when it refuses (the owner's "None of these", or a
    /// confirmed id the owner rejected), nothing else is applied either.
    /// The default photo is added only while the profile still has no
    /// default, no "no photo" and no rejection of its source; the migrated
    /// original replaces its photo in place only while that photo is still
    /// the default and the owner has not picked one; candidates are added
    /// when new and not rejected. Owner facts, owner photos, an owner-picked
    /// default, `noPhoto`, `notOnIPod` and the rejected ids are never
    /// changed. Does not save. Store I/O and image work: call it off the
    /// main actor, after `refuseWhileLibraryDisconnected`. Returns whether
    /// the identity and facts were applied.
    @discardableResult
    public func apply(to store: ArtistProfileStore, name: String, at date: Date) throws -> Bool {
        guard store.applyFetched(name: name, facts: facts, identity: identity, at: date),
              let profile = store.profile(forName: name) else { return false }
        let rejected = Set(profile.rejectedPhotoSources)

        if let photo = defaultPhoto, !profile.noPhoto,
           !profile.photos.contains(where: { $0.hash == profile.defaultPhoto }),
           Self.key(photo.source, photo.sourceID).map(rejected.contains) != true {
            do {
                try store.addPhoto(name: name, data: photo.data, source: photo.source, sourceID: photo.sourceID,
                                   credit: photo.credit)
            } catch ArtistProfileStoreError.unreadablePhoto, ArtistProfileStoreError.photoTooLarge {
                // Not a picture the store keeps: the profile goes without.
            }
        }

        if let replacement = replacementForMigrated, !profile.noPhoto, !profile.defaultPickedByOwner,
           profile.defaultPhoto == replacement.hash,
           let old = profile.photos.first(where: { $0.hash == replacement.hash }), old.source == .migrated {
            try replace(old, with: replacement.data, in: store, name: name)
        }

        let candidates = photoCandidates
        if !candidates.isEmpty {
            store.update(name: name) { profile in
                var known = Set(profile.rejectedPhotoSources).union(profile.photos.compactMap(\.rejectionKey))
                known.formUnion(profile.photoCandidates.map(ArtistLookupRun.rejectionKey))
                for candidate in candidates where known.insert(ArtistLookupRun.rejectionKey(candidate)).inserted {
                    profile.photoCandidates.append(candidate)
                }
            }
        }
        return true
    }

    /// The original takes the migrated photo's place and its role as
    /// default, under the source the migrated id names (`deezer:42` becomes
    /// Deezer's `42`). The old entry is dropped without being remembered as
    /// removed, so its source stays welcome; its file goes at the next save.
    private func replace(_ old: ArtistPhoto, with data: Data, in store: ArtistProfileStore, name: String) throws {
        var source = ArtistPhoto.Source.migrated
        var sourceID = old.sourceID
        if let parts = old.sourceID?.split(separator: ":", maxSplits: 1), parts.count == 2,
           let named = ArtistPhoto.Source(rawValue: String(parts[0])), named != .owner, named != .migrated {
            source = named
            sourceID = String(parts[1])
        }
        let new: ArtistPhoto
        do {
            new = try store.addPhoto(name: name, data: data, source: source, sourceID: sourceID, credit: old.credit)
        } catch ArtistProfileStoreError.unreadablePhoto, ArtistProfileStoreError.photoTooLarge {
            return
        }
        guard new.hash != old.hash else { return }
        store.update(name: name) { profile in
            guard profile.defaultPhoto == old.hash, !profile.defaultPickedByOwner,
                  let at = profile.photos.firstIndex(where: { $0.hash == old.hash }) else { return }
            profile.photos.removeAll { $0.hash == new.hash }
            let index = min(at, profile.photos.count - 1)
            profile.photos[index] = new
            profile.defaultPhoto = new.hash
        }
    }

    private static func key(_ source: ArtistPhoto.Source, _ sourceID: String?) -> String? {
        ArtistPhoto(hash: "", source: source, sourceID: sourceID, pixelWidth: 0, pixelHeight: 0,
                    added: .distantPast).rejectionKey
    }
}
