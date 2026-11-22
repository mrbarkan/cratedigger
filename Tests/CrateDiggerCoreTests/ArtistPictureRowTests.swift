import XCTest
@testable import CrateDiggerCore

/// What the Artist Pictures sheet shows for each artist, read from the
/// artist profiles: the iPod gets the artist's default photo.
final class ArtistPictureRowTests: XCTestCase {
    private var folder: URL!
    private var store: ArtistProfileStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let candidate = ArtistPictureCandidate(
        name: "Air", source: .commons, sourceID: "Q1", imageURL: URL(string: "https://upload.wikimedia.org/a.jpg")!,
        credit: ArtistPictureCredit(fileName: "Air live.jpg", licence: "CC BY 4.0", author: "A. Person"))

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPictureRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ArtistProfileStore(indexDirectory: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func artist(_ name: String, tracks: Int = 3) -> ArtistOnDevice {
        ArtistOnDevice(name: name, albumFolders: ["Music/\(name)/2000 Album"], trackCount: tracks)
    }

    private func tree(peopleFiles: [String] = []) -> DeviceArtTree {
        DeviceArtTree(peopleFiles: peopleFiles, coverFiles: [], folderImages: [:], foldersWithAudio: [],
                      artistsByFolder: [:])
    }

    private func jpeg(_ name: String) -> Data {
        FakePictureFetcher.jpeg(width: 600, height: 600, red: CGFloat(name.utf8.reduce(0) { $0 + Int($1) } % 97) / 97)
    }

    @discardableResult
    private func found(_ name: String, source: ArtistPhoto.Source, sourceID: String? = "1",
                       picked: Bool = false) throws -> ArtistPhoto {
        let photo = try store.addPhoto(name: name, data: jpeg(name), source: source, sourceID: sourceID, credit: nil)
        if picked { store.setDefault(name: name, hash: photo.hash) }
        return photo
    }

    private func only(_ name: String, tree: DeviceArtTree? = nil, uncertain: [String: [ArtistPictureCandidate]] = [:],
                      edits: [String: ArtistPictureEdit] = [:]) -> ArtistPictureRow {
        ArtistPictureRow.rows(artists: [artist(name)], tree: tree ?? self.tree(), profiles: store,
                              uncertain: uncertain, edits: edits, now: now)[0]
    }

    func testRowForPictureAlreadyOnDevice() throws {
        try found("Air", source: .deezer)
        let row = only("Air", tree: tree(peopleFiles: ["Air.jpg"]))
        XCTAssertEqual(row.state, .onDevice)
        XCTAssertEqual(row.badge, "DEVICE")
        XCTAssertEqual(row.devicePath, "Artwork/People/Air.jpg")
        XCTAssertEqual(row.id, "air")
    }

    func testRowReadyFromStore() throws {
        let photo = try found("Air", source: .deezer)
        let row = only("Air")
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(row.badge, "DEEZER")
        XCTAssertEqual(row.photoHash, photo.hash, "the sheet shows the default photo's own bytes")

        // A default photo whose file is gone is not ready.
        let gone = try found("Can", source: .deezer)
        try FileManager.default.removeItem(at: store.photoURL(hash: gone.hash))
        XCTAssertEqual(only("Can").state, .none)
        // Nor one too small for the iPod (the preparer wants 300 px).
        try store.addPhoto(name: "Low", data: FakePictureFetcher.jpeg(width: 200, height: 200), source: .owner,
                           sourceID: nil, credit: nil)
        XCTAssertEqual(only("Low").state, .none)
    }

    func testRowCheckWhenUncertain() {
        let row = only("Air", uncertain: ["air": [candidate]])
        XCTAssertEqual(row.state, .check)
        XCTAssertEqual(row.badge, "CHECK")
        XCTAssertEqual(row.candidates, [candidate])
        XCTAssertEqual(row.candidates.first?.credit?.author, "A. Person", "the Commons credit travels with it")
    }

    func testRowNoneWhenNothingKnown() throws {
        XCTAssertEqual(only("Air").state, .none)
        XCTAssertEqual(only("Air").badge, "NONE")
        store.update(name: "Air") { $0.photoSearchedAt = self.now }
        XCTAssertEqual(only("Air").state, .none)
    }

    func testRowRejected() throws {
        store.update(name: "Air") { $0.notOnIPod = true }
        XCTAssertEqual(only("Air").state, .rejected)
        XCTAssertEqual(only("Air").badge, "NOT ON IPOD")
        // "Don't Send to iPod" keeps the photo for the app.
        try found("Low", source: .deezer)
        store.update(name: "Low") { $0.notOnIPod = true }
        XCTAssertEqual(only("Low").state, .rejected)
        XCTAssertNotNil(store.profile(forName: "Low")?.defaultPhotoRef)
        // The owner's "No Photo" on the artist page sends nothing either.
        try found("Yes", source: .deezer)
        store.update(name: "Yes") { $0.noPhoto = true }
        XCTAssertEqual(only("Yes").state, .rejected)
        XCTAssertEqual(only("Yes").badge, "NO PICTURE")
        // The sheet's own edits win over the store until applied.
        XCTAssertEqual(only("Air", edits: ["air": .clear]).state, .none)
        XCTAssertEqual(only("Low", edits: ["low": .clear]).state, .ready, "Clear takes back only the sheet's word")
        XCTAssertEqual(only("Can", edits: ["can": .noPicture]).state, .rejected)
    }

    func testRowUnnameable() {
        let row = only("!!!")
        XCTAssertEqual(row.state, .unnameable)
        XCTAssertEqual(row.id, "!!!", "a name that folds to nothing keeps its own text as id")
    }

    func testBadgesBySource() throws {
        try found("Air", source: .library)
        try found("Can", source: .commons)
        try found("Low", source: .deezer, picked: true)
        try found("Yes", source: .owner, sourceID: nil)
        try found("Dido", source: .migrated, sourceID: "deezer:5")
        let badges = ArtistPictureRow.rows(artists: ["Air", "Can", "Low", "Yes", "Dido"].map { artist($0) },
                                           tree: tree(), profiles: store, uncertain: [:])
            .reduce(into: [String: String]()) { $0[$1.name] = $1.badge }
        XCTAssertEqual(badges, ["Air": "DISK", "Can": "COMMONS", "Low": "PICKED", "Yes": "PICKED", "Dido": "DEEZER"])
        let picked = only("Tool", edits: ["tool": .picked(prepared: Data("x".utf8), original: Data("x".utf8),
                                                          source: .commons, candidate: candidate)])
        XCTAssertEqual(picked.state, .ready)
        XCTAssertEqual(picked.badge, "PICKED")
        XCTAssertEqual(picked.credit?.fileName, "Air live.jpg")
    }

    func testRowsSortedByTrackCount() {
        let rows = ArtistPictureRow.rows(artists: [artist("Air", tracks: 2), artist("Can", tracks: 9),
                                                   artist("Bjork", tracks: 2)],
                                         tree: tree(), profiles: store, uncertain: [:])
        XCTAssertEqual(rows.map(\.name), ["Can", "Air", "Bjork"])
    }

    func testCanApplyNeedsAReadyRow() throws {
        XCTAssertFalse(ArtistPictureRow.canApply(ArtistPictureRow.rows(
            artists: [artist("Air")], tree: tree(), profiles: store, uncertain: ["air": [candidate]])))
        try found("Air", source: .deezer)
        XCTAssertTrue(ArtistPictureRow.canApply(ArtistPictureRow.rows(
            artists: [artist("Air")], tree: tree(), profiles: store, uncertain: [:])))
    }

    func testEditsApplyAsTheOwnersWord() throws {
        // A candidate picked in the sheet: the artist's default photo, the owner's pick.
        try ArtistPictureRow.apply(.picked(prepared: Data("x".utf8), original: jpeg("Air"), source: .commons,
                                           candidate: candidate), name: "Air", to: store)
        var profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertTrue(profile.defaultPickedByOwner)
        XCTAssertEqual(profile.defaultPhotoRef?.source, .commons)
        XCTAssertEqual(profile.defaultPhotoRef?.sourceID, "Q1")
        XCTAssertEqual(profile.defaultPhotoRef?.credit, candidate.credit)

        // A file of the owner's own, kept as given and made the default.
        let own = jpeg("own file")
        try ArtistPictureRow.apply(.picked(prepared: Data("x".utf8), original: own, source: .userFile, candidate: nil),
                                   name: "Air", to: store)
        profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(profile.defaultPhotoRef?.source, .owner)
        XCTAssertEqual(profile.photos.count, 2, "the earlier pick stays one of the artist's photos")
        XCTAssertEqual(store.photoData(hash: try XCTUnwrap(profile.defaultPhoto)), own)

        // "Don't Send to iPod" hides nothing in the app.
        try ArtistPictureRow.apply(.noPicture, name: "Air", to: store)
        XCTAssertEqual(store.profile(forName: "Air")?.notOnIPod, true)
        XCTAssertNotNil(store.profile(forName: "Air")?.defaultPhotoRef)

        // Clear takes it back for every spelling of the person.
        try ArtistPictureRow.apply(.clear, name: "AIR", to: store)
        XCTAssertEqual(store.profile(forName: "Air")?.notOnIPod, false)
        XCTAssertEqual(store.profile(forName: "Air")?.photos.count, 2, "Clear never removes a photo")

        // Picking a picture brings an artist back to the iPod.
        try ArtistPictureRow.apply(.noPicture, name: "Air", to: store)
        try ArtistPictureRow.apply(.picked(prepared: Data("x".utf8), original: own, source: .userFile, candidate: nil),
                                   name: "Air", to: store)
        XCTAssertEqual(store.profile(forName: "Air")?.notOnIPod, false)
    }

    // MARK: Held candidates and Find's 30-day rule

    func testHeldCandidatesFromTheStoreShowAsCheck() throws {
        store.update(name: "Air") { $0.photoCandidates = [ArtistPictureRecord.HeldCandidate(self.candidate)] }
        let row = only("Air")
        XCTAssertEqual(row.state, .check)
        XCTAssertEqual(row.candidates, [candidate])

        // What a Find in this session offered wins over what was held.
        let fresh = ArtistPictureCandidate(name: "Air", source: .deezer, sourceID: "d9",
                                           imageURL: URL(string: "https://e-cdns-images.dzcdn.net/z.jpg")!)
        XCTAssertEqual(only("Air", uncertain: ["air": [fresh]]).candidates, [fresh])
    }

    func testFindSkipsAFreshNotFoundUnlessAskedToLookAgain() throws {
        store.update(name: "Air") { $0.photoSearchedAt = self.now.addingTimeInterval(-86_400) }
        store.update(name: "Beck") { $0.photoSearchedAt = self.now.addingTimeInterval(-31 * 86_400) }
        store.update(name: "Can") { $0.photoCandidates = [ArtistPictureRecord.HeldCandidate(self.candidate)] }
        // A background lookup that left no photo counts as a search too.
        store.update(name: "Eno") { $0.checkedAt = self.now.addingTimeInterval(-2 * 86_400) }
        let rows = ArtistPictureRow.rows(artists: [artist("Air"), artist("Beck"), artist("Can"), artist("Dido"),
                                                   artist("Eno")],
                                         tree: tree(), profiles: store, uncertain: [:], now: now)
        let air = try XCTUnwrap(rows.first { $0.name == "Air" })
        XCTAssertEqual(air.state, .none)
        XCTAssertEqual(air.notFoundAt, now.addingTimeInterval(-86_400))
        XCTAssertNil(rows.first { $0.name == "Beck" }?.notFoundAt, "a stale not-found is asked again")

        XCTAssertEqual(Set(ArtistPictureRow.findTargets(rows).map(\.name)), ["Beck", "Can", "Dido"])
        XCTAssertEqual(Set(ArtistPictureRow.findTargets(rows, lookAgain: ["air"]).map(\.name)),
                       ["Air", "Beck", "Can", "Dido"])
    }
}
