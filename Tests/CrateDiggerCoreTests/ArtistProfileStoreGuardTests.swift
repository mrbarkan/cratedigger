import XCTest
@testable import CrateDiggerCore

/// The store's compare-and-apply writes: a lookup result lands only on the
/// identity it was computed for, checked under the same lock as the write.
final class ArtistProfileStoreGuardTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistProfileStoreGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var photoFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: scratch.appendingPathComponent(ArtistProfileStore.photosFolder).path)) ?? []
    }

    func testApplyFetchedIfIdentityIsRefusesAChangedIdentity() throws {
        let store = ArtistProfileStore(indexDirectory: scratch)
        let computedFor = ArtistProfile.Identity.confirmed(musicBrainzID: "mb-a", wikidataID: "Q1")
        store.update(name: "Air") { $0.identity = computedFor; $0.fetched = ArtistFacts(bio: "Old.") }

        // Between compute and apply, the owner pastes another id.
        let pasted = ArtistProfile.Identity.confirmed(musicBrainzID: "mb-pasted", wikidataID: nil)
        store.update(name: "Air") { $0.identity = pasted }
        let before = store.profile(forName: "Air")
        XCTAssertNil(store.applyFetched(name: "Air", facts: ArtistFacts(bio: "New."), identity: computedFor, at: now,
                                        ifIdentityIs: computedFor))
        XCTAssertEqual(store.profile(forName: "Air"), before)

        // Unchanged since: applied, and the identity written comes back.
        XCTAssertEqual(store.applyFetched(name: "Air", facts: ArtistFacts(bio: "New."), identity: pasted, at: now,
                                          ifIdentityIs: pasted), pasted)
        XCTAssertEqual(store.profile(forName: "Air")?.fetched?.bio, "New.")

        // No profile reads as `.unknown`; an uncertain list loses the rejected ids, and says so.
        store.update(name: "Boston") { $0.rejectedMusicBrainzIDs = ["mb-x"] }
        let asked = ArtistProfile.Identity.uncertain([ArtistIdentityCandidate(musicBrainzID: "mb-x", name: "Boston"),
                                                      ArtistIdentityCandidate(musicBrainzID: "mb-y", name: "Boston")])
        XCTAssertEqual(store.applyFetched(name: "Boston", facts: nil, identity: asked, at: now, ifIdentityIs: .unknown),
                       .uncertain([ArtistIdentityCandidate(musicBrainzID: "mb-y", name: "Boston")]))
        XCTAssertNotNil(store.applyFetched(name: "Can", facts: nil, identity: .notFound, at: now, ifIdentityIs: .unknown))
        // The owner's "None of these" still stands, and says nothing was applied.
        store.update(name: "Dido") { $0.identity = .rejected }
        XCTAssertNil(store.applyFetched(name: "Dido", facts: nil, identity: .notFound, at: now, ifIdentityIs: .rejected))
    }

    func testConditionalAddPhotoWritesNothingWhenRefused() throws {
        let store = ArtistProfileStore(indexDirectory: scratch)
        store.update(name: "Air") { $0.identity = .notFound }
        let before = store.profile(forName: "Air")
        var seen: (before: ArtistProfile?, photo: ArtistPhoto?) = (nil, nil)
        let refused = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(), source: .deezer, sourceID: "1",
                                         credit: nil) { current, after, photo in
            seen = (current, photo)
            XCTAssertEqual(after.photos.map(\.hash), [photo.hash], "the decision sees the photo added")
            return current?.identity == .unknown
        }
        XCTAssertNil(refused)
        XCTAssertEqual(seen.before, before)
        XCTAssertEqual(store.profile(forName: "Air"), before)
        XCTAssertEqual(photoFiles, [], "a refused photo leaves no file behind")

        let kept = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(), source: .deezer, sourceID: "1",
                                      credit: nil) { current, _, _ in current?.identity == .notFound }
        XCTAssertEqual(store.profile(forName: "Air")?.photos.map(\.hash), [try XCTUnwrap(kept).hash])
        XCTAssertEqual(store.profile(forName: "Air")?.defaultPhoto, kept?.hash)
        XCTAssertEqual(photoFiles.count, 1)

        // The same bytes again: the decision gets the photo already there and may move it.
        let other = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(red: 0.1), source: .owner,
                                       sourceID: nil, credit: nil)
        let again = try store.addPhoto(name: "Air", data: FakePictureFetcher.jpeg(), source: .deezer, sourceID: "1",
                                       credit: nil) { _, after, photo in
            after.photos.removeAll { $0.hash == photo.hash }
            after.photos.append(photo)
            return true
        }
        XCTAssertEqual(again, kept)
        XCTAssertEqual(store.profile(forName: "Air")?.photos.map(\.hash), [other.hash, kept!.hash])
    }

    func testGuardedUpdateRunsOnlyOnTheExpectedIdentity() {
        let store = ArtistProfileStore(indexDirectory: scratch)
        XCTAssertTrue(store.update(name: "Air", ifIdentityIs: .unknown) { $0.notOnIPod = false })
        store.update(name: "Air") { $0.identity = .notFound }
        XCTAssertFalse(store.update(name: "Air", ifIdentityIs: .unknown) { $0.noPhoto = true })
        XCTAssertEqual(store.profile(forName: "Air")?.noPhoto, false)
        XCTAssertTrue(store.update(name: "Air", ifIdentityIs: .notFound) { $0.noPhoto = true })
        XCTAssertEqual(store.profile(forName: "Air")?.noPhoto, true)
    }
}
