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
        // One Wikidata item read, for the bio and the image both.
        XCTAssertEqual(fetcher.requests.filter { $0 == CommonsArtistSource.entityURL(id: "Q11895") }.count, 1)

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
        // The original, not the iPod's 400 px copy, and downloaded once: the
        // finder's own download is kept.
        XCTAssertEqual(result.defaultPhoto?.data, FakePictureFetcher.jpeg(width: 1000, height: 1000))
        XCTAssertEqual(fetcher.requests.filter { $0 == deezerImage(8) }.count, 1)
    }

    func testUncertainGetsNoFactsAndAPhotoOnlyOnTwoTitles() async throws {
        info.candidates["Boston"] = .success([
            ArtistIdentityCandidate(musicBrainzID: "mb-rock", name: "Boston", origin: "Boston, United States"),
            ArtistIdentityCandidate(musicBrainzID: "mb-uk", name: "Boston", origin: "United Kingdom"),
        ])
        info.details["mb-rock"] = .success((ArtistFacts(kind: "Group"), "Q1", ["More Than a Feeling"]))
        info.details["mb-uk"] = .success((ArtistFacts(kind: "Group"), "Q2", ["Something Else"]))
        deezer.offered = [deezerCandidate(5, "Boston", albums: ["Third Stage", "Don't Look Back"])]
        fetcher.answer(deezerImage(5), data: FakePictureFetcher.jpeg())

        // One telling title in common: the finder's rule takes it, but with
        // no confirmed identity it is held for the owner, never the default.
        var result = try await lookUp("Boston", albums: ["Third Stage"])
        guard case .uncertain(let candidates) = result.identity else {
            return XCTFail("expected uncertain, got \(result.identity)")
        }
        XCTAssertEqual(candidates.map(\.musicBrainzID), ["mb-rock", "mb-uk"])
        XCTAssertNil(result.facts)
        XCTAssertTrue(info.bioCalls.isEmpty)
        XCTAssertNil(result.defaultPhoto)
        XCTAssertEqual(result.photoCandidates.map(\.sourceID), ["5"])

        // Two: it becomes the default the iPod would get.
        result = try await lookUp("Boston", albums: ["Third Stage", "Don't Look Back"])
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
        // The Wikidata item is read for the bio, but no picture is fetched.
        XCTAssertFalse(fetcher.requests.contains(commonsImage))
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

    func testADefaultWhoseFileHasGoneIsFoundAgain() async throws {
        answerMassiveAttack()
        let store = store()
        let name = "Massive Attack"
        let lost = try store.addPhoto(name: name, data: FakePictureFetcher.jpeg(red: 0.2), source: .deezer,
                                      sourceID: "3", credit: nil)
        try store.save()
        try FileManager.default.removeItem(at: store.photoURL(hash: lost.hash))

        let result = try await run().lookUp(name: name, libraryAlbumTitles: ["Mezzanine"], libraryPicture: nil,
                                            existing: store.profile(forName: name), lane: .background, now: now,
                                            photoFileExists: { store.hasPhotoFile(hash: $0) })
        XCTAssertEqual(result.defaultPhoto?.source, .commons, "counted as no default")
        XCTAssertTrue(try result.apply(to: store, name: name, at: now))
        let after = try XCTUnwrap(store.profile(forName: name))
        XCTAssertNotEqual(after.defaultPhoto, lost.hash)
        XCTAssertTrue(store.hasPhotoFile(hash: try XCTUnwrap(after.defaultPhoto)))
        XCTAssertFalse(after.defaultPickedByOwner)

        // The owner's pick stays a pick: the placeholder shows, the reference is kept.
        let picked = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(red: 0.4), source: .owner,
                                        sourceID: nil, credit: nil)
        store.setDefault(name: "Air", hash: picked.hash)
        try FileManager.default.removeItem(at: store.photoURL(hash: picked.hash))
        info.candidates["Air"] = .success([])
        let again = try await run().lookUp(name: "Air", libraryAlbumTitles: [], libraryPicture: nil,
                                           existing: store.profile(forName: "Air"), lane: .background, now: now,
                                           photoFileExists: { store.hasPhotoFile(hash: $0) })
        XCTAssertNil(again.defaultPhoto)
        XCTAssertEqual(deezer.calls, 0)
        XCTAssertEqual(store.profile(forName: "Air")?.defaultPhoto, picked.hash)
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

        // A picture that will not download stops the lookup when the service
        // is down. (A Deezer pick is downloaded once, by the finder, so the
        // run's own download is the Wikidata portrait's.)
        deezer.failure = nil
        answerMassiveAttack(image: true)
        fetcher.answer(commonsImage, with: [.failure(ArtistPictureSourceError.http(502))])
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
        result.basedOn = before.identity
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
        XCTAssertEqual(after.photoCandidates, [], "no candidates under no photo")
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
        XCTAssertEqual(store.profile(forName: name)?.photoCandidates.map(\.sourceID), ["9"],
                       "a removed source is never offered again")
        XCTAssertEqual(store.profile(forName: name)?.rejectedPhotoSources, ["commons:mb-ma", "deezer:7"])
    }

    func testStaleResultIsNotApplied() async throws {
        answerMassiveAttack()
        let store = store()
        let name = "Massive Attack"
        store.update(name: name) { profile in
            profile.identity = .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895")
            profile.fetched = ArtistFacts(kind: "Group", bio: "Old.")
        }
        // A 180-day refresh starts from the confirmed record...
        let refresh = try await lookUp(existing: store.profile(forName: name))
        XCTAssertEqual(refresh.basedOn, .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))

        // ... and the owner pastes another id before it lands.
        store.update(name: name) { $0.identity = .confirmed(musicBrainzID: "mb-pasted", wikidataID: nil) }
        let before = store.profile(forName: name)
        XCTAssertFalse(try refresh.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name), before)

        // A search that started while the page was asking, landing after the owner picked one.
        let held = ArtistProfile.Identity.uncertain([ArtistIdentityCandidate(musicBrainzID: "mb-ma", name: name)])
        var search = try await lookUp(existing: nil)
        search.basedOn = held
        store.update(name: name) { $0.identity = .confirmed(musicBrainzID: "mb-ma", wikidataID: nil) }
        XCTAssertFalse(try search.apply(to: store, name: name, at: now))
        XCTAssertEqual(store.profile(forName: name)?.identity, .confirmed(musicBrainzID: "mb-ma", wikidataID: nil))
        XCTAssertEqual(store.profile(forName: name)?.photos, [])
    }

    func testMigratedSwapKeepsThePhotosAroundIt() async throws {
        info.candidates["Air"] = .success([])
        let store = store()
        let original = FakePictureFetcher.jpeg(width: 1000, height: 1000, red: 0.4)
        // A: the original's bytes, already a photo. M: the migrated default. O: the owner's.
        let a = try store.addPhoto(name: "Air", data: original, source: .deezer, sourceID: "42", credit: nil)
        let m = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(width: 400, height: 400, red: 0.4),
                                   source: .migrated, sourceID: "deezer:42", credit: nil)
        let o = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(red: 0.1), source: .owner,
                                   sourceID: nil, credit: nil)
        let held = URL(string: "https://e-cdns-images.dzcdn.net/images/artist/held/1000x1000.jpg")!
        fetcher.answer(held, data: original)
        store.update(name: "Air") { profile in
            profile.defaultPhoto = m.hash
            profile.photos[1].replaceFromURL = held
        }
        XCTAssertEqual(store.profile(forName: "Air")?.photos.map(\.hash), [a.hash, m.hash, o.hash])

        let result = try await lookUp("Air", existing: store.profile(forName: "Air"))
        XCTAssertEqual(result.replacementForMigrated?.hash, m.hash)
        XCTAssertTrue(try result.apply(to: store, name: "Air", at: now))
        let after = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(after.photos.map(\.hash), [a.hash, o.hash], "the owner's photo is kept")
        XCTAssertEqual(after.photos.last, o)
        XCTAssertEqual(after.defaultPhoto, a.hash)
        XCTAssertFalse(after.defaultPickedByOwner)
    }

    func testConfirmedIdentityLeavesCommonsOut() async throws {
        // Under a confirmed identity the artist's own Wikidata image is known
        // (or there is none): any Commons pick is a namesake's, so the
        // finder's Commons source is never asked.
        answerMassiveAttack(image: false)
        let commons = FakePictureSource(id: .commons)
        let image = URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/Namesake.jpg?width=800")!
        fetcher.answer(image, data: FakePictureFetcher.jpeg())
        commons.offered = [ArtistPictureCandidate(name: "Massive Attack", source: .commons, sourceID: "mb-ma",
                                                  imageURL: image, albumTitles: ["Mezzanine"])]
        let run = ArtistLookupRun(info: info, pictures: ArtistPictureFinder(sources: [commons], fetcher: fetcher,
                                                                            quotaBackoff: []),
                                  fetcher: fetcher, preferredLanguages: ["en"], spacing: .zero)
        let result = try await run.lookUp(name: "Massive Attack", libraryAlbumTitles: ["Mezzanine"],
                                          libraryPicture: nil, existing: nil, lane: .background, now: now)
        XCTAssertEqual(result.identity, .confirmed(musicBrainzID: "mb-ma", wikidataID: "Q11895"))
        XCTAssertNil(result.defaultPhoto)
        XCTAssertTrue(result.photoCandidates.isEmpty)
        XCTAssertEqual(commons.calls, 0)
        XCTAssertFalse(fetcher.requests.contains(image))
    }

    func testUncertainCommonsCandidatesComeFromTheIdentitySearch() async throws {
        info.candidates["Boston"] = .success([
            ArtistIdentityCandidate(musicBrainzID: "mb-rock", name: "Boston"),
            ArtistIdentityCandidate(musicBrainzID: "mb-uk", name: "Boston"),
        ])
        info.details["mb-rock"] = .success((ArtistFacts(kind: "Group"), "Q1", ["Third Stage", "Walk On"]))
        info.details["mb-uk"] = .success((ArtistFacts(kind: "Group"), "Q2", ["Something Else"]))
        fetcher.answer(CommonsArtistSource.entityURL(id: "Q1"), json: """
            {"entities":{"Q1":{"claims":{"P18":[{"mainsnak":{"datavalue":{"value":"Boston band.jpg"}}}]}}}}
            """)
        let image = CommonsArtistParser.imageURL(fileName: "Boston band.jpg", width: 1_600)
        fetcher.answer(image, data: FakePictureFetcher.jpeg(width: 700, height: 700))
        fetcher.answer(DeezerArtistParser.searchURL(name: "Boston"), json: "{\"data\":[]}")
        let commons = FakePictureSource(id: .commons)
        let run = ArtistLookupRun(info: info,
                                  pictures: ArtistPictureFinder(sources: [DeezerArtistSource(fetcher: fetcher,
                                                                                             spacing: .zero),
                                                                          commons],
                                                                fetcher: fetcher, quotaBackoff: []),
                                  fetcher: fetcher, preferredLanguages: ["en"], spacing: .zero)

        let result = try await run.lookUp(name: "Boston", libraryAlbumTitles: ["Third Stage"], libraryPicture: nil,
                                          existing: nil, lane: .background, now: now)
        guard case .uncertain = result.identity else { return XCTFail("expected uncertain, got \(result.identity)") }
        // The acts the identity search looked up, by their own Wikidata items:
        // no second MusicBrainz search, no Commons source of the finder's.
        XCTAssertEqual(commons.calls, 0)
        XCTAssertEqual(info.candidateCalls, ["Boston"])
        XCTAssertTrue(fetcher.requests.contains(CommonsArtistSource.entityURL(id: "Q1")))
        XCTAssertTrue(fetcher.requests.contains(CommonsArtistSource.entityURL(id: "Q2")))
        XCTAssertFalse(fetcher.requests.contains { $0.host == "musicbrainz.org" })
        let offered = [result.defaultPhoto?.sourceID].compactMap { $0 } + result.photoCandidates.map(\.sourceID)
        XCTAssertEqual(offered, ["mb-rock"])
    }

    func testASlowPhotoSearchStillLandsTheIdentityAndTheWorkerMovesOn() async throws {
        // "Low": confirmed by its albums, no Wikidata image, and a Deezer
        // that answers far past the photo's time.
        info.candidates["Low"] = .success([ArtistIdentityCandidate(musicBrainzID: "mb-low", name: "Low")])
        info.details["mb-low"] = .success((ArtistFacts(kind: "Group"), nil, ["Things We Lost in the Fire"]))
        info.candidates["Air"] = .success([ArtistIdentityCandidate(musicBrainzID: "mb-air", name: "Air")])
        info.details["mb-air"] = .success((ArtistFacts(kind: "Group"), nil, ["Moon Safari"]))
        fetcher.answer(DeezerArtistParser.searchURL(name: "Air"), json: "{\"data\":[]}")
        let slow = SlowPictureFetcher(fetcher, slow: [DeezerArtistParser.searchURL(name: "Low")], delay: .seconds(20))
        let run = ArtistLookupRun(info: info,
                                  pictures: ArtistPictureFinder(sources: [DeezerArtistSource(fetcher: slow,
                                                                                             spacing: .zero)],
                                                                fetcher: slow, perArtist: .milliseconds(300),
                                                                quotaBackoff: []),
                                  fetcher: slow, preferredLanguages: ["en"], spacing: .zero)
        let store = store()
        let library = [(name: "Low", trackCount: 40), (name: "Air", trackCount: 10)]
        let albums = ["Low": ["Things We Lost in the Fire"], "Air": ["Moon Safari"]]
        var session = ArtistLookupSession()
        var looked: [String] = []
        let started = ContinuousClock.now

        // The worker's loop, as it runs: the next due artist, looked up, applied.
        for _ in 0..<3 {
            let due = ArtistLookupScheduler().due(artists: library, profiles: { store.profile(forName: $0) },
                                                  priority: [], now: now)
                .filter { !session.skipped.contains(PodBoxArtName.folded($0)) }
            guard let name = due.first else { break }
            looked.append(name)
            let key = PodBoxArtName.folded(name)
            let result = try await run.lookUp(name: name, libraryAlbumTitles: albums[name] ?? [], libraryPicture: nil,
                                              existing: store.profile(forName: name), lane: .background, now: now,
                                              findsPhoto: session.findsPhoto(key))
            XCTAssertTrue(try result.apply(to: store, name: name, at: now))
            session.succeeded(key, photoTimedOut: result.photoTimedOut)
        }

        XCTAssertEqual(looked, ["Low", "Air"], "the slow artist no longer holds the library back")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        let low = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(low.identity, .confirmed(musicBrainzID: "mb-low", wikidataID: nil))
        XCTAssertEqual(low.fetched?.kind, "Group")
        XCTAssertEqual(low.photos, [], "nothing about the photo is stored")
        XCTAssertEqual(low.photoCandidates, [])
        XCTAssertFalse(session.findsPhoto("low"), "its photo is left alone for the session")
        XCTAssertTrue(session.findsPhoto("air"))
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .confirmed(musicBrainzID: "mb-air", wikidataID: nil))
    }

    func testBackgroundRunAsksMusicBrainzOnlyInTheBackground() async throws {
        let gate = MusicBrainzGate(interval: .zero)
        let client = ArtistInfoClient(fetcher: fetcher, gate: gate, wikimediaSpacing: .zero)
        fetcher.answer(ArtistInfoClient.searchURL(name: "Boston"), json: "{\"artists\":[]}")
        fetcher.answer(CommonsArtistSource.searchURL(name: "Boston"),
                       json: "{\"artists\":[{\"id\":\"mb-boston\",\"name\":\"Boston\",\"score\":100}]}")
        fetcher.answer(CommonsArtistSource.artistURL(id: "mb-boston"), json: "{\"id\":\"mb-boston\",\"relations\":[]}")
        let finder = ArtistPictureFinder(sources: [CommonsArtistSource(fetcher: fetcher, musicBrainzGate: gate,
                                                                       wikimedia: RequestSpacer(spacing: .zero))],
                                         fetcher: fetcher, quotaBackoff: [])
        let run = ArtistLookupRun(info: client, pictures: finder, fetcher: fetcher, spacing: .zero)

        let result = try await run.lookUp(name: "Boston", libraryAlbumTitles: ["Third Stage"], libraryPicture: nil,
                                          existing: nil, lane: .background, now: now)
        XCTAssertEqual(result.identity, .notFound)
        // The photo search makes no second MusicBrainz search: only the identity search ran.
        XCTAssertFalse(fetcher.requests.contains(CommonsArtistSource.searchURL(name: "Boston")))
        let issued = await gate.issued
        XCTAssertNil(issued[.foreground], "a background run made a foreground MusicBrainz request")
        XCTAssertEqual(issued[.background], 1)

        // The finder's callers outside the lookup stay in the foreground.
        _ = await finder.find([(name: "Boston", deviceAlbumTitles: [], libraryPicture: nil)])
        let after = await gate.issued
        XCTAssertEqual(after[.foreground], 2)
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

        // ... or asked for no photo. (Each step starts the identity over: a
        // result whose starting identity has moved on is stale.)
        store.update(name: name) { $0.identity = .unknown; $0.rejectedPhotoSources = []; $0.noPhoto = true }
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

    func bio(entity: Data, wikidataID: String,
             preferredLanguages: [String]) async throws -> (extract: String, pageURL: URL)? {
        locked {
            calls.bios.append(wikidataID)
            return _bios[wikidataID]
        }
    }
}

/// Answers through `base`, but the URLs in `slow` only after `delay`
/// (cancellable, as a real request is).
final class SlowPictureFetcher: ArtistPictureFetching, @unchecked Sendable {
    private let base: FakePictureFetcher
    private let slow: Set<URL>
    private let delay: Duration

    init(_ base: FakePictureFetcher, slow: Set<URL>, delay: Duration) {
        self.base = base
        self.slow = slow
        self.delay = delay
    }

    func data(from url: URL) async throws -> Data {
        if slow.contains(url) { try await Task.sleep(for: delay) }
        return try await base.data(from: url)
    }
}

/// A picture source with fixed candidates (their album titles included), or a failure.
final class FakePictureSource: ArtistPictureSource, @unchecked Sendable {
    let id: ArtistPictureSourceID
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

    init(id: ArtistPictureSourceID = .deezer) {
        self.id = id
    }

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
