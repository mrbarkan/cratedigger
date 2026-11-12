import XCTest
@testable import CrateDiggerCore

/// The Edit Artist sheet's draft: what the owner types lands in `owner` and
/// nowhere else, "Use the looked-up value" hands a field back, and a pasted
/// MusicBrainz link or id changes who the artist is, dropping what came with
/// the old identity and keeping everything the owner set.
final class ArtistEditDraftTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let oldID = "10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8"
    private let newID = "cb67438a-7f50-4f2b-a6f1-2bb2729fd538"

    private func photo(_ hash: String, _ source: ArtistPhoto.Source, id: String? = nil) -> ArtistPhoto {
        ArtistPhoto(hash: hash, source: source, sourceID: id, pixelWidth: 800, pixelHeight: 800, added: date)
    }

    private func confirmedProfile() -> ArtistProfile {
        ArtistProfile(foldedKey: "massiveattack", displayName: "Massive Attack",
                      identity: .confirmed(musicBrainzID: oldID, wikidataID: "Q11895"),
                      fetched: ArtistFacts(kind: "Group", origin: "Bristol, England", begin: "1988",
                                           bio: "A band.", bioSourceURL: URL(string: "https://en.wikipedia.org/wiki/X"),
                                           genres: ["trip hop"]),
                      owner: ArtistFacts(genres: ["dub"]),
                      photos: [photo("a", .commons, id: oldID), photo("b", .owner), photo("c", .deezer, id: "9")],
                      photoCandidates: [ArtistPictureRecord.HeldCandidate(
                          source: .deezer, sourceID: "10", imageURL: URL(string: "https://e.dzcdn.net/x.jpg")!)],
                      defaultPhoto: "b", defaultPickedByOwner: true, noPhoto: false, notOnIPod: true, checkedAt: date)
    }

    // MARK: - Owner fields

    func testEditsGoToOwnerOnly() {
        var profile = confirmedProfile()
        let before = profile
        var draft = ArtistEditDraft(profile: profile)
        XCTAssertEqual(draft.fetched, before.fetched, "the placeholders come from the looked-up facts")
        XCTAssertEqual(draft.owner, ArtistFacts(genres: ["dub"]))

        draft.owner.origin = "London"
        draft.owner.bio = "  Written by me.  "
        draft.apply(to: &profile)

        XCTAssertEqual(profile.owner, ArtistFacts(origin: "London", bio: "Written by me.", genres: ["dub"]))
        XCTAssertEqual(profile.fetched, before.fetched, "a save never writes the looked-up facts")
        XCTAssertEqual(profile.identity, before.identity)
        XCTAssertEqual(profile.photos, before.photos)
        XCTAssertEqual(profile.defaultPhoto, before.defaultPhoto)
        XCTAssertEqual(profile.checkedAt, before.checkedAt)
        XCTAssertEqual(profile.facts.origin, "London")
        XCTAssertEqual(profile.facts.kind, "Group", "fields the owner left alone still show the looked-up value")
        XCTAssertNil(profile.facts.bioSourceURL, "an owner's bio carries no Wikipedia credit")
    }

    func testUseLookedUpClearsOwnerField() {
        var profile = confirmedProfile()
        profile.owner = ArtistFacts(origin: "London", begin: "", genres: ["dub"])
        var draft = ArtistEditDraft(profile: profile)

        draft.useLookedUp(\ArtistFacts.origin)
        XCTAssertNil(draft.owner.origin)
        XCTAssertEqual(draft.owner.begin, "", "only the field asked for goes back")
        XCTAssertEqual(draft.owner.genres, ["dub"])

        draft.useLookedUp(\ArtistFacts.begin)
        draft.useLookedUp(\ArtistFacts.genres)
        XCTAssertEqual(draft.owner, ArtistFacts())
        draft.apply(to: &profile)
        XCTAssertNil(profile.owner, "nothing of the owner's left: no owner set at all")
        XCTAssertEqual(profile.facts.origin, "Bristol, England")
        XCTAssertEqual(profile.facts.genres, ["trip hop"])
    }

    func testAnEmptyOwnerFieldStillHidesTheLookedUpOne() {
        var profile = confirmedProfile()
        var draft = ArtistEditDraft(profile: profile)
        draft.owner.origin = ""
        draft.apply(to: &profile)
        XCTAssertEqual(profile.owner?.origin, "")
        XCTAssertNil(profile.facts.origin, "an owner's empty field is the owner clearing it")
    }

    func testOpeningAndSavingChangesNothing() {
        var profile = confirmedProfile()
        let before = profile
        ArtistEditDraft(profile: profile).apply(to: &profile)
        XCTAssertEqual(profile, before)
        XCTAssertFalse(ArtistEditDraft(profile: profile).changesIdentity(of: profile))
    }

    // MARK: - MusicBrainz ids

    func testMusicBrainzLinkAndBareIDParse() {
        let id = "10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8"
        let accepted = [
            id,
            "  \(id.uppercased())\n",
            "https://musicbrainz.org/artist/\(id)",
            "http://musicbrainz.org/artist/\(id)",
            "https://musicbrainz.org/artist/\(id)/releases",
            "https://musicbrainz.org/artist/\(id)?tab=works#top",
            "https://beta.musicbrainz.org/artist/\(id)",
            "musicbrainz.org/artist/\(id)",
            "https://www.musicbrainz.org/artist/\(id)/",
        ]
        for text in accepted {
            XCTAssertEqual(ArtistEditDraft.musicBrainzID(from: text), id, text)
        }
    }

    func testGarbageIsNotAnID() {
        let id = "10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8"
        let refused = [
            "", "   ", "Massive Attack", "10adbe5e-a2c0-4bf3-8249", "\(id)x", "zzadbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8",
            "https://musicbrainz.org/release/\(id)",
            "https://musicbrainz.org/artist/",
            "https://musicbrainz.org/artist/not-an-id",
            "https://example.com/artist/\(id)",
            "https://musicbrainz.org.example.com/artist/\(id)",
            "ftp://musicbrainz.org/artist/\(id)",
            "https://en.wikipedia.org/wiki/Massive_Attack",
        ]
        for text in refused {
            XCTAssertNil(ArtistEditDraft.musicBrainzID(from: text), text)
        }
    }

    // MARK: - Changing who the artist is

    func testIdentityChangeKeepsOwnerDataDropsFetched() {
        var profile = confirmedProfile()
        var draft = ArtistEditDraft(profile: profile)
        draft.owner.origin = "London"
        draft.pastedMusicBrainz = "https://musicbrainz.org/artist/\(newID)"
        XCTAssertTrue(draft.changesIdentity(of: profile))

        draft.apply(to: &profile)

        XCTAssertEqual(profile.identity, .confirmed(musicBrainzID: newID, wikidataID: nil))
        XCTAssertNil(profile.checkedAt, "due at once, so the new identity's facts are looked up")
        XCTAssertNil(profile.fetched, "the old identity's facts go")
        XCTAssertTrue(profile.photoCandidates.isEmpty, "and the photos it found")
        XCTAssertEqual(profile.photos.map(\.hash), ["b"], "its Commons and Deezer photos go; the owner's stays")
        XCTAssertEqual(profile.defaultPhoto, "b")
        XCTAssertTrue(profile.defaultPickedByOwner)
        XCTAssertEqual(profile.owner, ArtistFacts(origin: "London", genres: ["dub"]))
        XCTAssertTrue(profile.notOnIPod)
    }

    func testPastingTheSameIDChangesNoIdentity() {
        var profile = confirmedProfile()
        let before = profile
        var draft = ArtistEditDraft(profile: profile)
        draft.pastedMusicBrainz = oldID.uppercased()
        XCTAssertFalse(draft.changesIdentity(of: profile))
        draft.apply(to: &profile)
        XCTAssertEqual(profile, before)
    }

    func testPastingAnIDOnAnUncertainArtistDropsPhotosFoundByName() {
        var profile = confirmedProfile()
        profile.identity = .notFound
        profile.fetched = nil
        profile.defaultPickedByOwner = false
        profile.defaultPhoto = "c"
        profile.photos.append(photo("d", .library, id: "/m/MA/artist.jpg"))
        var draft = ArtistEditDraft(profile: profile)
        draft.pastedMusicBrainz = newID
        draft.apply(to: &profile)
        XCTAssertEqual(profile.photos.map(\.hash), ["b", "d"])
        XCTAssertEqual(profile.defaultPhoto, "b", "the next photo left takes over")
        XCTAssertFalse(profile.defaultPickedByOwner)
    }

    func testPastingAnIDTheOwnerRejectedTakesItBack() {
        var profile = confirmedProfile()
        profile.identity = .rejected
        profile.rejectedMusicBrainzIDs = [newID]
        var draft = ArtistEditDraft(profile: profile)
        draft.pastedMusicBrainz = newID
        draft.apply(to: &profile)
        XCTAssertEqual(profile.identity, .confirmed(musicBrainzID: newID, wikidataID: nil))
        XCTAssertTrue(profile.rejectedMusicBrainzIDs.isEmpty)
    }

    func testAnUnreadablePasteChangesNothing() {
        var profile = confirmedProfile()
        let before = profile
        var draft = ArtistEditDraft(profile: profile)
        draft.pastedMusicBrainz = "not a link"
        XCTAssertFalse(draft.pasteIsReadable)
        XCTAssertFalse(draft.changesIdentity(of: profile))
        draft.apply(to: &profile)
        XCTAssertEqual(profile, before)
    }

    func testNotThisArtistRejectsTheConfirmedID() {
        var profile = confirmedProfile()
        var draft = ArtistEditDraft(profile: profile)
        draft.rejectsIdentity = true
        XCTAssertTrue(draft.changesIdentity(of: profile))
        draft.apply(to: &profile)
        XCTAssertEqual(profile.identity, .unknown)
        XCTAssertEqual(profile.rejectedMusicBrainzIDs, [oldID])
        XCTAssertNil(profile.fetched)
        XCTAssertEqual(profile.photos.map(\.hash), ["b"])
        XCTAssertEqual(profile.owner, ArtistFacts(genres: ["dub"]))
    }

    func testNotThisArtistThenTheRightOne() {
        var profile = confirmedProfile()
        var draft = ArtistEditDraft(profile: profile)
        draft.rejectsIdentity = true
        draft.pastedMusicBrainz = newID
        draft.apply(to: &profile)
        XCTAssertEqual(profile.identity, .confirmed(musicBrainzID: newID, wikidataID: nil))
        XCTAssertEqual(profile.rejectedMusicBrainzIDs, [oldID])
    }

    func testNotThisArtistOnAnUnconfirmedArtistDoesNothing() {
        var profile = confirmedProfile()
        profile.identity = .notFound
        let before = profile
        var draft = ArtistEditDraft(profile: profile)
        draft.rejectsIdentity = true
        XCTAssertFalse(draft.changesIdentity(of: profile))
        draft.apply(to: &profile)
        XCTAssertEqual(profile, before)
    }

    // MARK: - List fields as text

    func testGenresText() {
        XCTAssertEqual(ArtistEditDraft.genresText(["trip hop", "dub"]), "trip hop, dub")
        XCTAssertEqual(ArtistEditDraft.genres(fromText: " trip hop ,, dub,  "), ["trip hop", "dub"])
        XCTAssertEqual(ArtistEditDraft.genres(fromText: "  "), [])
    }

    func testMembersTextRoundTrips() {
        let members = [
            ArtistMember(name: "Robert Del Naja", begin: "1988", isCurrent: true),
            ArtistMember(name: "Andrew Vowles", begin: "1988", end: "1999", isCurrent: false),
            ArtistMember(name: "Horace Andy", isCurrent: true),
            ArtistMember(name: "Tricky", isCurrent: false),
            ArtistMember(name: "Someone", end: "1995", isCurrent: false),
        ]
        let text = ArtistEditDraft.membersText(members)
        XCTAssertEqual(text, """
            Robert Del Naja (1988 to now)
            Andrew Vowles (1988 to 1999)
            Horace Andy
            Tricky (former)
            Someone (until 1995)
            """)
        XCTAssertEqual(ArtistEditDraft.members(fromText: text), members)
    }

    func testMembersTextKeepsOtherParenthesesInTheName() {
        XCTAssertEqual(ArtistEditDraft.members(fromText: "  Mark (Spike) Stent  \n\n"),
                       [ArtistMember(name: "Mark (Spike) Stent", isCurrent: true)])
        XCTAssertEqual(ArtistEditDraft.members(fromText: "Daddy G (1988-2001)"),
                       [ArtistMember(name: "Daddy G", begin: "1988", end: "2001", isCurrent: false)])
        XCTAssertEqual(ArtistEditDraft.members(fromText: "Daddy G (1988 to Now)"),
                       [ArtistMember(name: "Daddy G", begin: "1988", isCurrent: true)])
    }

    func testLinksText() {
        let links = ArtistEditDraft.links(fromText: """
            https://musicbrainz.org/artist/\(oldID)
              https://en.wikipedia.org/wiki/Massive_Attack
            https://massiveattack.co.uk
            not a link
            ftp://example.com/x
            """)
        XCTAssertEqual(links, [
            ArtistLink(kind: .musicBrainz, url: URL(string: "https://musicbrainz.org/artist/\(oldID)")!),
            ArtistLink(kind: .wikipedia, url: URL(string: "https://en.wikipedia.org/wiki/Massive_Attack")!),
            ArtistLink(kind: .other, url: URL(string: "https://massiveattack.co.uk")!),
        ])
        XCTAssertEqual(ArtistEditDraft.linksText(links), """
            https://musicbrainz.org/artist/\(oldID)
            https://en.wikipedia.org/wiki/Massive_Attack
            https://massiveattack.co.uk
            """)
    }
}
