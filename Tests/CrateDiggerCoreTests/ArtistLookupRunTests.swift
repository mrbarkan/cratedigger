import XCTest
@testable import CrateDiggerCore

/// One artist's lookup against fakes: who they are, their facts and bio, a
/// default photo only when the profile may take one, and nothing the owner
/// set ever changed when the result is applied. Never the network.
final class ArtistLookupRunTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let wikipedia = URL(string: "https://en.wikipedia.org/wiki/Massive_Attack")!
    private var fetcher: FakePictureFetcher!
    private var info: FakeArtistInfo!
    private var deezer: FakePictureSource!
    private var scratch: URL!

    override func setUpWithError() throws {
        fetcher = FakePictureFetcher()
        info = FakeArtistInfo()
        deezer = FakePictureSource()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistLookupRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    private func run() -> ArtistLookupRun {
        ArtistLookupRun(info: info,
                        pictures: ArtistPictureFinder(sources: [deezer], fetcher: fetcher, quotaBackoff: []),
                        fetcher: fetcher, deezer: deezer, preferredLanguages: ["en"], spacing: .zero)
    }

    private func lookUp(_ name: String = "Massive Attack", albums: [String] = ["Mezzanine"], picture: URL? = nil,
                        existing: ArtistProfile? = nil) async throws -> ArtistLookupResult {
        try await run().lookUp(name: name, libraryAlbumTitles: albums, libraryPicture: picture, existing: existing,
                               lane: .background, now: now)
    }

    private func deezerImage(_ id: Int) -> URL {
        URL(string: "https://e-cdns-images.dzcdn.net/images/artist/\(id)/1000x1000.jpg")!
    }

    private func deezerCandidate(_ id: Int, _ name: String, albums: [String]) -> ArtistPictureCandidate {
        ArtistPictureCandidate(name: name, source: .deezer, sourceID: String(id), imageURL: deezerImage(id),
                               albumTitles: albums)
    }

    /// Massive Attack, confirmed on MusicBrainz by "Mezzanine", with a
    /// Wikidata item that has an image and an English article.
    private func answerMassiveAttack(image: Bool = true) {
        info.candidates["Massive Attack"] = .success([
            ArtistIdentityCandidate(musicBrainzID: "mb-ma", name: "Massive Attack"),
            ArtistIdentityCandidate(musicBrainzID: "mb-other", name: "Massive Attacks Tribute"),
        ])
        info.details["mb-ma"] = .success((
            ArtistFacts(kind: "Group", origin: "Bristol, United Kingdom", begin: "1988",
                        links: [ArtistLink(kind: .musicBrainz, url: URL(string: "https://musicbrainz.org/artist/mb-ma")!)]),
            "Q11895", ["Blue Lines", "Mezzanine"]))
        info.bios["Q11895"] = ("Massive Attack are an English trip hop group.", wikipedia)
        let p18 = image
            ? ",\"claims\":{\"P18\":[{\"mainsnak\":{\"datavalue\":{\"value\":\"Massive Attack 2008.jpg\",\"type\":\"string\"}}}]}"
            : ""
        fetcher.answer(CommonsArtistSource.entityURL(id: "Q11895"),
                       json: "{\"entities\":{\"Q11895\":{\"id\":\"Q11895\"\(p18)}}}")
        fetcher.answer(commonsImage, data: FakePictureFetcher.jpeg(width: 900, height: 900))
    }

    private var commonsImage: URL {
        CommonsArtistParser.imageURL(fileName: "Massive Attack 2008.jpg", width: 1_600)
    }

    private func store() -> ArtistProfileStore {
        ArtistProfileStore(indexDirectory: scratch)
    }

    // MARK: Identity, facts and the first photo

    func testConfirmedFetchesFactsBioAndPhoto() async throws {
        answerMassiveAttack()
        let result = try await lookUp()

        XCTAssertEqual(result.identity, .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))
        let facts = try XCTUnwrap(result.facts)
        XCTAssertEqual(facts.kind, "Group")
        XCTAssertEqual(facts.bio, "Massive Attack are an English trip hop group.")
        XCTAssertEqual(facts.bioSourceURL, wikipedia)
        XCTAssertEqual(facts.links?.map(\.kind), [.musicBrainz, .wikipedia])
        XCTAssertEqual(facts.links?.last?.url, wikipedia)
        // Only the name-equal candidate was looked up; the bio in English.
        XCTAssertEqual(info.detailCalls, ["mb-ma"])
        XCTAssertEqual(info.bioCalls, ["Q11895"])

        // The Wikidata image is trusted for a confirmed identity: no Deezer.
        let photo = try XCTUnwrap(result.defaultPhoto)
        XCTAssertEqual(photo.source, .commons)
        XCTAssertEqual(photo.sourceID, "mb-ma")
        XCTAssertEqual(photo.credit?.fileName, "Massive Attack 2008.jpg")
        XCTAssertEqual(photo.data, FakePictureFetcher.jpeg(width: 900, height: 900))
        XCTAssertEqual(deezer.calls, 0)
        XCTAssertTrue(info.lanes.allSatisfy { $0 == .background })
    }

    func testConfirmedWithoutWikidataImageTakesOnlyANameEqualDeezerPick() async throws {
        answerMassiveAttack(image: false)
        // The finder's rule takes this one ("Mezzanine"), but it is not the
        // confirmed artist's name once folded: held, not downloaded.
        deezer.offered = [deezerCandidate(7, "Attack, Massive", albums: ["Mezzanine"])]
        fetcher.answer(deezerImage(7), data: FakePictureFetcher.jpeg())
        var result = try await lookUp()
        XCTAssertNil(result.defaultPhoto)
        XCTAssertEqual(result.photoCandidates.map(\.sourceID), ["7"])

        deezer.offered = [deezerCandidate(8, "Massive Attack", albums: ["Mezzanine"])]
        fetcher.answer(deezerImage(8), data: FakePictureFetcher.jpeg(width: 1000, height: 1000))
        result = try await lookUp()
        XCTAssertEqual(result.defaultPhoto?.source, .deezer)
        XCTAssertEqual(result.defaultPhoto?.sourceID, "8")
        // The original, not the iPod's 400 px copy.
        XCTAssertEqual(result.defaultPhoto?.data, FakePictureFetcher.jpeg(width: 1000, height: 1000))
    }

    func testUncertainGetsNoFactsButMayGetPhoto() async throws {
        info.candidates["Boston"] = .success([
            ArtistIdentityCandidate(musicBrainzID: "mb-rock", name: "Boston", origin: "Boston, United States"),
            ArtistIdentityCandidate(musicBrainzID: "mb-uk", name: "Boston", origin: "United Kingdom"),
        ])
        info.details["mb-rock"] = .success((ArtistFacts(kind: "Group"), "Q1", ["More Than a Feeling"]))
        info.details["mb-uk"] = .success((ArtistFacts(kind: "Group"), "Q2", ["Something Else"]))
        deezer.offered = [deezerCandidate(5, "Boston", albums: ["Third Stage"])]
        fetcher.answer(deezerImage(5), data: FakePictureFetcher.jpeg())

        let result = try await lookUp("Boston", albums: ["Third Stage"])
        guard case .uncertain(let candidates) = result.identity else {
            return XCTFail("expected uncertain, got \(result.identity)")
        }
        XCTAssertEqual(candidates.map(\.musicBrainzID), ["mb-rock", "mb-uk"])
        XCTAssertNil(result.facts)
        XCTAssertTrue(info.bioCalls.isEmpty)
        // The finder's own rule still picks the photo the iPod would get.
        XCTAssertEqual(result.defaultPhoto?.source, .deezer)
        XCTAssertEqual(result.defaultPhoto?.sourceID, "5")
    }

    func testLibraryFolderPictureComesFirst() async throws {
        answerMassiveAttack()
        let file = scratch.appendingPathComponent("artist.jpg")
        try FakePictureFetcher.jpeg(width: 640, height: 640).write(to: file)
        let result = try await lookUp(picture: file)
        XCTAssertEqual(result.defaultPhoto?.source, .library)
        XCTAssertEqual(result.defaultPhoto?.sourceID, file.path)
        XCTAssertFalse(fetcher.requests.contains(commonsImage))
        XCTAssertEqual(deezer.calls, 0)
    }

    func testRefreshAsksByTheConfirmedID() async throws {
        answerMassiveAttack()
        info.candidates["Massive Attack"] = .failure(ArtistPictureSourceError.http(500)) // never asked
        let existing = ArtistProfile(foldedKey: "massiveattack", displayName: "Massive Attack",
                                     identity: .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))
        let result = try await lookUp(existing: existing)
        XCTAssertEqual(result.identity, .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))
        XCTAssertEqual(info.candidateCalls, [])
        XCTAssertEqual(result.facts?.bio, "Massive Attack are an English trip hop group.")
    }

    func testDeletedConfirmedIDLosesTheIdentity() async throws {
        info.details["mb-gone"] = .failure(ArtistPictureSourceError.http(404))
        let store = store()
        store.update(name: "Massive Attack") { profile in
            profile.identity = .confirmed(musicBrainzID: "mb-gone", wikidataID: "Q11895")
            profile.fetched = ArtistFacts(kind: "Group", bio: "Old.")
            profile.owner = ArtistFacts(origin: "Bristol")
            profile.checkedAt = now.addingTimeInterval(-200 * 86_400)
        }
        let result = try await lookUp(existing: store.profile(forName: "Massive Attack"))
        XCTAssertEqual(result.identity, .unknown)
        XCTAssertNil(result.facts)
        XCTAssertNil(result.defaultPhoto)
        XCTAssertEqual(info.candidateCalls, [], "the next run searches, not this one")

        XCTAssertTrue(try result.apply(to: store, name: "Massive Attack", at: now))
        let after = try XCTUnwrap(store.profile(forName: "Massive Attack"))
        XCTAssertEqual(after.identity, .unknown)
        XCTAssertNil(after.fetched)
        XCTAssertEqual(after.owner, ArtistFacts(origin: "Bristol"))
        // Not "not found" for 30 days, and not a failure retried for ever: due again now.
        XCTAssertEqual(ArtistLookupScheduler().due(artists: [("Massive Attack", 10)],
                                                   profiles: { store.profile(forName: $0) }, priority: [], now: now),
                       ["Massive Attack"])
    }

    // MARK: Photos the owner decided about

    func testOwnerDefaultIsNeverReplaced() async throws {
        answerMassiveAttack()
        let store = store()
        let mine = try store.addPhoto(name: "Massive Attack", data: FakePictureFetcher.jpeg(red: 0.1), source: .owner,
                                      sourceID: nil, credit: nil)
        store.setDefault(name: "Massive Attack", hash: mine.hash)
        var result = try await lookUp(existing: store.profile(forName: "Massive Attack"))
        XCTAssertNil(result.defaultPhoto)
        XCTAssertNil(result.replacementForMigrated)

        // A looked-up default the owner did not pick is kept too: it is not migrated.
        let found = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(red: 0.2), source: .deezer,
                                       sourceID: "3", credit: nil)
        XCTAssertEqual(store.profile(forName: "Air")?.defaultPhoto, found.hash)
        info.candidates["Air"] = .success([])
        result = try await lookUp("Air", existing: store.profile(forName: "Air"))
        XCTAssertNil(result.defaultPhoto)
        XCTAssertFalse(fetcher.requests.contains(commonsImage))
        XCTAssertEqual(deezer.calls, 0)
    }

    func testRejectedPhotoSourceIsSkipped() async throws {
        answerMassiveAttack()
        deezer.offered = [deezerCandidate(7, "Massive Attack", albums: ["Mezzanine"])]
        fetcher.answer(deezerImage(7), data: FakePictureFetcher.jpeg())
        let existing = ArtistProfile(foldedKey: "massiveattack", displayName: "Massive Attack",
                                     rejectedPhotoSources: ["commons:mb-ma", "deezer:7"])
        let result = try await lookUp(existing: existing)
        XCTAssertNil(result.defaultPhoto)
        XCTAssertTrue(result.photoCandidates.isEmpty)
        XCTAssertFalse(fetcher.requests.contains(commonsImage), "a removed photo is not even downloaded")
    }

    func testNoPhotoFetchesNoPhoto() async throws {
        answerMassiveAttack()
        let existing = ArtistProfile(foldedKey: "massiveattack", displayName: "Massive Attack", noPhoto: true)
        let result = try await lookUp(existing: existing)
        XCTAssertNotNil(result.facts)
        XCTAssertNil(result.defaultPhoto)
        XCTAssertTrue(result.photoCandidates.isEmpty)
        XCTAssertFalse(fetcher.requests.contains(CommonsArtistSource.entityURL(id: "Q11895")))
        XCTAssertEqual(deezer.calls, 0)
    }

    func testMigratedPhotoGetsItsOriginal() async throws {
        info.candidates["Air"] = .success([])
        let store = store()
        let small = FakePictureFetcher.jpeg(width: 400, height: 400, red: 0.4)
        let original = FakePictureFetcher.jpeg(width: 1000, height: 1000, red: 0.4)

        // From the address the migration recorded.
        let held = URL(string: "https://e-cdns-images.dzcdn.net/images/artist/held/1000x1000.jpg")!
        fetcher.answer(held, data: original)
        let migrated = try store.addPhoto(name: "Air", data: small, source: .migrated, sourceID: "deezer:42", credit: nil)
        store.update(name: "Air") { $0.photos[0].replaceFromURL = held }
        var result = try await lookUp("Air", existing: store.profile(forName: "Air"))
        XCTAssertEqual(result.replacementForMigrated?.hash, migrated.hash)
        XCTAssertEqual(result.replacementForMigrated?.data, original)
        XCTAssertNil(result.defaultPhoto)

        // Without one: Deezer is asked again for the artist by its id.
        store.update(name: "Air") { $0.photos[0].replaceFromURL = nil }
        deezer.offered = [deezerCandidate(41, "Air", albums: []), deezerCandidate(42, "Air", albums: [])]
        fetcher.answer(deezerImage(42), data: original)
        result = try await lookUp("Air", existing: store.profile(forName: "Air"))
        XCTAssertEqual(result.replacementForMigrated?.hash, migrated.hash)
        XCTAssertEqual(result.replacementForMigrated?.data, original)

        // Applied: the original takes the migrated photo's place and its role,
        // under Deezer's own id, and nothing is remembered as removed.
        XCTAssertTrue(try result.apply(to: store, name: "Air", at: now))
        let after = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(after.photos.count, 1)
        XCTAssertEqual(after.photos[0].source, .deezer)
        XCTAssertEqual(after.photos[0].sourceID, "42")
        XCTAssertEqual(after.photos[0].pixelWidth, 1000)
        XCTAssertEqual(after.defaultPhoto, after.photos[0].hash)
        XCTAssertNotEqual(after.defaultPhoto, migrated.hash)
        XCTAssertFalse(after.defaultPickedByOwner)
        XCTAssertTrue(after.rejectedPhotoSources.isEmpty)

        // The owner's pick of a migrated photo stays as it is.
        let picked = ArtistProfile(foldedKey: "air", displayName: "Air", photos: [migrated],
                                   defaultPhoto: migrated.hash, defaultPickedByOwner: true)
        result = try await lookUp("Air", existing: picked)
        XCTAssertNil(result.replacementForMigrated)
    }

    // MARK: Failures

    func testFailureStoresNothing() async throws {
        let store = store()
        store.update(name: "Massive Attack") { $0.owner = ArtistFacts(origin: "Bristol") }
        let before = store.profile(forName: "Massive Attack")

        for failure: ArtistPictureSourceError in [.http(503), .http(429), .transport("offline")] {
            info.candidates["Massive Attack"] = .failure(failure)
            do {
                _ = try await lookUp(existing: before)
                XCTFail("\(failure) became an answer")
            } catch {
                XCTAssertEqual(error as? ArtistPictureSourceError, failure)
                XCTAssertTrue(failure.stopsTheRun)
            }
        }

        // The finder failing to reach its service is a failure too, never "no photo".
        answerMassiveAttack(image: false)
        deezer.failure = ArtistPictureSourceError.transport("offline")
        do {
            _ = try await lookUp(existing: before)
            XCTFail("a failed picture lookup became an answer")
        } catch {
            guard case .pictureLookupFailed? = error as? ArtistLookupError else { return XCTFail("\(error)") }
        }

        // A picture that will not download stops the lookup when the service is down.
        deezer.failure = nil
        deezer.offered = [deezerCandidate(8, "Massive Attack", albums: ["Mezzanine"])]
        fetcher.answer(deezerImage(8), with: [.success(FakePictureFetcher.jpeg()), .failure(ArtistPictureSourceError.http(502))])
        do {
            _ = try await lookUp(existing: before)
            XCTFail("a 502 became an answer")
        } catch {
            XCTAssertEqual(error as? ArtistPictureSourceError, .http(502))
        }
        XCTAssertEqual(store.profile(forName: "Massive Attack"), before)
    }

    // MARK: Applying a result never changes the owner's choices

    func testRefreshKeepsOwnerChoices() async throws {
        answerMassiveAttack()
        let store = store()
        let name = "Massive Attack"
        let mine = try store.addPhoto(name: name, data: FakePictureFetcher.jpeg(red: 0.1), source: .owner,
                                      sourceID: nil, credit: nil)
        let theirs = try store.addPhoto(name: name, data: FakePictureFetcher.jpeg(red: 0.6), source: .deezer,
                                        sourceID: "3", credit: nil)
        store.setDefault(name: name, hash: mine.hash)
        store.update(name: name) { profile in
            profile.identity = .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895")
            profile.owner = ArtistFacts(kind: "Collective", origin: "", bio: "My own words.",
                                        members: [ArtistMember(name: "3D", isCurrent: true)], genres: [])
            profile.noPhoto = true
            profile.notOnIPod = true
            profile.rejectedMusicBrainzIDs = ["mb-other"]
            profile.rejectedPhotoSources = ["commons:mb-ma", "deezer:7"]
            profile.checkedAt = now.addingTimeInterval(-181 * 86_400)
        }
        let before = try XCTUnwrap(store.profile(forName: name))

        // The worst case: a result found as if the profile had nothing, with a
        // default photo, a replacement and candidates, applied on top of it.
        var result = try await lookUp(existing: nil)
        XCTAssertNotNil(result.defaultPhoto)
        result.replacementForMigrated = (mine.hash, FakePictureFetcher.jpeg(width: 900, height: 900))
        result.photoCandidates += [9, 7].map {
            ArtistPictureRecord.HeldCandidate(source: .deezer, sourceID: String($0), imageURL: deezerImage($0))
        }
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        try store.save()

        let after = try XCTUnwrap(ArtistProfileStore(indexDirectory: scratch).profile(forName: name))
        XCTAssertEqual(after.owner, before.owner)
        XCTAssertEqual(after.photos, before.photos)
        XCTAssertEqual(after.photos.map(\.hash), [mine.hash, theirs.hash])
        XCTAssertEqual(after.defaultPhoto, mine.hash)
        XCTAssertTrue(after.defaultPickedByOwner)
        XCTAssertTrue(after.noPhoto)
        XCTAssertTrue(after.notOnIPod)
        XCTAssertEqual(after.rejectedMusicBrainzIDs, ["mb-other"])
        XCTAssertEqual(after.rejectedPhotoSources, ["commons:mb-ma", "deezer:7"])
        XCTAssertEqual(after.photoCandidates.map(\.sourceID), ["9"], "a removed source is never offered again")
        // Only the lookup's own fields moved.
        XCTAssertEqual(after.fetched?.bio, "Massive Attack are an English trip hop group.")
        XCTAssertEqual(after.facts.bio, "My own words.")
        XCTAssertNil(after.facts.bioSourceURL)
        XCTAssertEqual(after.checkedAt, now)

        // Without "no photo", an owner-picked default still stands against a result's photo.
        store.update(name: name) { $0.noPhoto = false }
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name)?.defaultPhoto, mine.hash)
        XCTAssertEqual(store.profile(forName: name)?.photos.map(\.hash), [mine.hash, theirs.hash])
    }

    func testApplyRechecksWhatTheOwnerDidMeanwhile() async throws {
        answerMassiveAttack()
        let store = store()
        let name = "Massive Attack"
        let result = try await lookUp(existing: store.profile(forName: name))
        XCTAssertNotNil(result.defaultPhoto)

        // While the lookup ran, the owner removed that photo once already.
        store.update(name: name) { $0.rejectedPhotoSources = ["commons:mb-ma"] }
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name)?.photos, [])

        // ... or asked for no photo.
        store.update(name: name) { $0.rejectedPhotoSources = []; $0.noPhoto = true }
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name)?.photos, [])
        store.update(name: name) { $0.noPhoto = false }

        // ... or said "None of these": nothing of the result lands.
        store.update(name: name) { $0.identity = .rejected; $0.rejectedPhotoSources = [] }
        XCTAssertFalse(try result.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name)?.identity, .rejected)
        XCTAssertEqual(store.profile(forName: name)?.photos, [])

        // With nothing in the way, the photo becomes the (not owner-picked) default.
        store.update(name: name) { $0.identity = .unknown }
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        let after = try XCTUnwrap(store.profile(forName: name))
        XCTAssertEqual(after.photos.map(\.source), [.commons])
        XCTAssertEqual(after.defaultPhoto, after.photos.first?.hash)
        XCTAssertFalse(after.defaultPickedByOwner)
        XCTAssertEqual(after.identity, .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))
    }
}

// MARK: - Fakes

/// Answers the artist info calls from dictionaries; anything not set is a 404.
final class FakeArtistInfo: ArtistInfoFetching, @unchecked Sendable {
    typealias Detail = (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String])

    private let lock = NSLock()
    private var _candidates: [String: Result<[ArtistIdentityCandidate], Error>] = [:]
    private var _details: [String: Result<Detail, Error>] = [:]
    private var _bios: [String: (extract: String, pageURL: URL)] = [:]
    private var calls: (candidates: [String], details: [String], bios: [String], lanes: [MusicBrainzGate.Lane])
        = ([], [], [], [])

    var candidates: [String: Result<[ArtistIdentityCandidate], Error>] {
        get { locked { _candidates } }
        set { locked { _candidates = newValue } }
    }
    var details: [String: Result<Detail, Error>] {
        get { locked { _details } }
        set { locked { _details = newValue } }
    }
    var bios: [String: (extract: String, pageURL: URL)] {
        get { locked { _bios } }
        set { locked { _bios = newValue } }
    }
    var candidateCalls: [String] { locked { calls.candidates } }
    var detailCalls: [String] { locked { calls.details } }
    var bioCalls: [String] { locked { calls.bios } }
    var lanes: [MusicBrainzGate.Lane] { locked { calls.lanes } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistIdentityCandidate] {
        try locked { () -> Result<[ArtistIdentityCandidate], Error> in
            calls.candidates.append(name)
            calls.lanes.append(lane)
            return _candidates[name] ?? .failure(ArtistPictureSourceError.http(404))
        }.get()
    }

    func detail(musicBrainzID: String, lane: MusicBrainzGate.Lane) async throws -> Detail {
        try locked { () -> Result<Detail, Error> in
            calls.details.append(musicBrainzID)
            calls.lanes.append(lane)
            return _details[musicBrainzID] ?? .failure(ArtistPictureSourceError.http(404))
        }.get()
    }

    func bio(wikidataID: String, preferredLanguages: [String]) async throws -> (extract: String, pageURL: URL)? {
        locked {
            calls.bios.append(wikidataID)
            return _bios[wikidataID]
        }
    }
}

/// A picture source with fixed candidates (their album titles included), or a failure.
final class FakePictureSource: ArtistPictureSource, @unchecked Sendable {
    var id: ArtistPictureSourceID { .deezer }
    private let lock = NSLock()
    private var _offered: [ArtistPictureCandidate] = []
    private var _failure: Error?
    private var _calls = 0

    var offered: [ArtistPictureCandidate] {
        get { lock.withLock { _offered } }
        set { lock.withLock { _offered = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func candidates(for name: String) async throws -> [ArtistPictureCandidate] {
        let (offered, failure) = lock.withLock { () -> ([ArtistPictureCandidate], Error?) in
            _calls += 1
            return (_offered, _failure)
        }
        if let failure { throw failure }
        return offered.filter { PodBoxArtName.matches($0.name, name) }
    }

    func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String] { candidate.albumTitles }
}
