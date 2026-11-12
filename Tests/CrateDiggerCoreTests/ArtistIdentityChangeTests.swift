import XCTest
@testable import CrateDiggerCore

/// The owner settling who an artist is from the artist page: "Is this them?",
/// "None of these" and "Not This Artist". The owner's own data never moves.
final class ArtistIdentityChangeTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func photo(_ hash: String, _ source: ArtistPhoto.Source, id: String? = nil) -> ArtistPhoto {
        ArtistPhoto(hash: hash, source: source, sourceID: id, pixelWidth: 800, pixelHeight: 800, added: date)
    }

    private var candidates: [ArtistIdentityCandidate] {
        [ArtistIdentityCandidate(musicBrainzID: "mb-1", name: "Air", disambiguation: "French duo"),
         ArtistIdentityCandidate(musicBrainzID: "mb-2", name: "Air", disambiguation: "Japanese band")]
    }

    private func confirmedProfile() -> ArtistProfile {
        ArtistProfile(foldedKey: "air", displayName: "Air", identity: .confirmed(musicBrainzID: "mb-1", wikidataID: "Q1"),
                      fetched: ArtistFacts(kind: "Group", bio: "A duo."), owner: ArtistFacts(origin: "Versailles"),
                      photos: [photo("a", .commons, id: "mb-1"), photo("b", .owner), photo("c", .deezer, id: "9"),
                               photo("d", .library, id: "/m/Air/artist.jpg")],
                      photoCandidates: [ArtistPictureRecord.HeldCandidate(source: .deezer, sourceID: "10",
                                                                          imageURL: URL(string: "https://e.dzcdn.net/x.jpg")!)],
                      defaultPhoto: "a", noPhoto: false, notOnIPod: true, checkedAt: date)
    }

    func testPickingACandidateConfirmsIt() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air", identity: .uncertain(candidates),
                                    photos: [photo("c", .deezer, id: "9")], defaultPhoto: "c", checkedAt: date)
        profile.confirmIdentity(musicBrainzID: "mb-2")
        XCTAssertEqual(profile.identity, .confirmed(musicBrainzID: "mb-2", wikidataID: nil))
        XCTAssertNil(profile.checkedAt, "due at once, so its facts are looked up by the id")
        XCTAssertEqual(profile.photos.map(\.hash), ["c"], "an uncertain artist's photo was not the identity's")
        XCTAssertEqual(profile.defaultPhoto, "c")
    }

    func testPickingAnIDTheOwnerRejectedTakesItBack() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air", identity: .uncertain(candidates),
                                    rejectedMusicBrainzIDs: ["mb-2", "mb-9"])
        profile.confirmIdentity(musicBrainzID: "mb-2")
        XCTAssertEqual(profile.rejectedMusicBrainzIDs, ["mb-9"])
    }

    func testConfirmingTheSameIDChangesNothing() {
        var profile = confirmedProfile()
        let before = profile
        profile.confirmIdentity(musicBrainzID: "mb-1")
        XCTAssertEqual(profile, before)
    }

    func testNoneOfTheseRejectsAndKeepsEverythingElse() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air", identity: .uncertain(candidates),
                                    owner: ArtistFacts(bio: "Mine"), photos: [photo("b", .owner)], defaultPhoto: "b",
                                    defaultPickedByOwner: true)
        profile.rejectCandidates()
        XCTAssertEqual(profile.identity, .rejected)
        XCTAssertEqual(profile.owner, ArtistFacts(bio: "Mine"))
        XCTAssertEqual(profile.photos.map(\.hash), ["b"])
        XCTAssertTrue(profile.rejectedMusicBrainzIDs.isEmpty,
                      "Look Up Again must be free to offer the same candidates again")
    }

    func testNotThisArtistRejectsTheIDAndDropsWhatCameWithIt() {
        var profile = confirmedProfile()
        profile.rejectConfirmedIdentity()
        XCTAssertEqual(profile.identity, .unknown)
        XCTAssertEqual(profile.rejectedMusicBrainzIDs, ["mb-1"])
        XCTAssertNil(profile.fetched)
        XCTAssertNil(profile.checkedAt)
        XCTAssertEqual(profile.owner, ArtistFacts(origin: "Versailles"))
        XCTAssertEqual(profile.photos.map(\.hash), ["b", "d"], "the owner's photo and their library folder's stay")
        XCTAssertTrue(profile.photoCandidates.isEmpty)
        XCTAssertEqual(profile.defaultPhoto, "b", "the old identity's default went, so the next photo takes over")
        XCTAssertFalse(profile.defaultPickedByOwner)
        XCTAssertTrue(profile.notOnIPod)
    }

    func testNotThisArtistKeepsAnOwnerPickedDefault() {
        var profile = confirmedProfile()
        profile.defaultPhoto = "c"
        profile.defaultPickedByOwner = true
        profile.rejectConfirmedIdentity()
        XCTAssertEqual(profile.photos.map(\.hash), ["b", "c", "d"])
        XCTAssertEqual(profile.defaultPhoto, "c")
        XCTAssertTrue(profile.defaultPickedByOwner)
    }

    func testNotThisArtistOnlyActsOnAConfirmedArtist() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air", identity: .uncertain(candidates))
        let before = profile
        profile.rejectConfirmedIdentity()
        XCTAssertEqual(profile, before)
    }

    func testNotThisArtistWithNoPhotoLeftClearsTheDefault() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air",
                                    identity: .confirmed(musicBrainzID: "mb-1", wikidataID: nil),
                                    photos: [photo("a", .commons, id: "mb-1")], defaultPhoto: "a")
        profile.rejectConfirmedIdentity()
        XCTAssertTrue(profile.photos.isEmpty)
        XCTAssertNil(profile.defaultPhoto)
    }
}
