import XCTest
@testable import CrateDiggerCore

/// What the Artist Pictures sheet shows for each artist.
final class ArtistPictureRowTests: XCTestCase {
    private var folder: URL!
    private var store: ArtistPictureStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let candidate = ArtistPictureCandidate(
        name: "Air", source: .commons, sourceID: "Q1", imageURL: URL(string: "https://upload.wikimedia.org/a.jpg")!,
        credit: ArtistPictureCredit(fileName: "Air live.jpg", licence: "CC BY 4.0", author: "A. Person"))

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPictureRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ArtistPictureStore(indexDirectory: folder, imageDirectory: folder.appendingPathComponent("Images"))
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

    private func found(_ name: String, source: ArtistPictureSourceID, picked: Bool = false) throws {
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: name, outcome: .found, source: source,
                                          pickedByUser: picked, checkedAt: now), prepared: Data("jpeg \(name)".utf8))
    }

    private func only(_ name: String, tree: DeviceArtTree? = nil, uncertain: [String: [ArtistPictureCandidate]] = [:],
                      edits: [String: ArtistPictureEdit] = [:]) -> ArtistPictureRow {
        ArtistPictureRow.rows(artists: [artist(name)], tree: tree ?? self.tree(), store: store,
                              uncertain: uncertain, edits: edits)[0]
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
        try found("Air", source: .deezer)
        let row = only("Air")
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(row.badge, "DEEZER")

        // A record whose cached picture is gone is not ready.
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Can", outcome: .found, source: .deezer,
                                          preparedHash: String(repeating: "b", count: 64), checkedAt: now),
                      prepared: nil)
        XCTAssertEqual(only("Can").state, .none)
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
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Air", outcome: .notFound, checkedAt: now),
                      prepared: nil)
        XCTAssertEqual(only("Air").state, .none)
    }

    func testRowRejected() throws {
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Air", outcome: .rejected, pickedByUser: true,
                                          checkedAt: now), prepared: nil)
        XCTAssertEqual(only("Air").state, .rejected)
        XCTAssertEqual(only("Air").badge, "NO PICTURE")
        // The sheet's own edits win over the store until applied.
        XCTAssertEqual(only("Air", edits: ["air": .clear]).state, .none)
        XCTAssertEqual(only("Can", edits: ["can": .noPicture]).state, .rejected)
    }

    func testRowUnnameable() {
        let row = only("!!!")
        XCTAssertEqual(row.state, .unnameable)
        XCTAssertEqual(row.id, "!!!", "a name that folds to nothing keeps its own text as id")
    }

    func testBadgesBySource() throws {
        try found("Air", source: .libraryFolder)
        try found("Can", source: .commons)
        try found("Low", source: .deezer, picked: true)
        try found("Yes", source: .userFile)
        let badges = ArtistPictureRow.rows(artists: ["Air", "Can", "Low", "Yes"].map { artist($0) }, tree: tree(),
                                           store: store, uncertain: [:])
            .reduce(into: [String: String]()) { $0[$1.name] = $1.badge }
        XCTAssertEqual(badges, ["Air": "DISK", "Can": "COMMONS", "Low": "PICKED", "Yes": "PICKED"])
        let picked = only("Tool", edits: ["tool": .picked(prepared: Data("x".utf8), source: .commons,
                                                          candidate: candidate)])
        XCTAssertEqual(picked.state, .ready)
        XCTAssertEqual(picked.badge, "PICKED")
        XCTAssertEqual(picked.credit?.fileName, "Air live.jpg")
    }

    func testRowsSortedByTrackCount() {
        let rows = ArtistPictureRow.rows(artists: [artist("Air", tracks: 2), artist("Can", tracks: 9),
                                                   artist("Bjork", tracks: 2)],
                                         tree: tree(), store: store, uncertain: [:])
        XCTAssertEqual(rows.map(\.name), ["Can", "Air", "Bjork"])
    }

    func testCanApplyNeedsAReadyRow() throws {
        XCTAssertFalse(ArtistPictureRow.canApply(ArtistPictureRow.rows(
            artists: [artist("Air")], tree: tree(), store: store, uncertain: ["air": [candidate]])))
        try found("Air", source: .deezer)
        XCTAssertTrue(ArtistPictureRow.canApply(ArtistPictureRow.rows(
            artists: [artist("Air")], tree: tree(), store: store, uncertain: [:])))
    }

    func testEditRecordsAreTheOwnersWord() throws {
        let (picked, bytes) = try XCTUnwrap(ArtistPictureRow.record(
            for: .picked(prepared: Data("x".utf8), source: .commons, candidate: candidate), name: "Air", now: now))
        XCTAssertTrue(picked.pickedByUser)
        XCTAssertEqual(picked.credit, candidate.credit)
        XCTAssertEqual(bytes, Data("x".utf8))
        let (rejected, none) = try XCTUnwrap(ArtistPictureRow.record(for: .noPicture, name: "Air", now: now))
        XCTAssertEqual(rejected.outcome, .rejected)
        XCTAssertNil(none)
        XCTAssertNil(ArtistPictureRow.record(for: .clear, name: "Air", now: now))

        try store.set(rejected, prepared: nil)
        store.remove(forName: "AIR")
        XCTAssertNil(store.record(forName: "Air"), "Clear forgets every spelling of the person")
    }

    // MARK: Held candidates and Find's 30-day rule

    func testHeldCandidatesFromTheStoreShowAsCheck() throws {
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Air", outcome: .uncertain, checkedAt: now,
                                          candidates: [ArtistPictureRecord.HeldCandidate(candidate)]), prepared: nil)
        let row = only("Air")
        XCTAssertEqual(row.state, .check)
        XCTAssertEqual(row.candidates, [candidate])

        // What a Find in this session offered wins over what was held.
        let fresh = ArtistPictureCandidate(name: "Air", source: .deezer, sourceID: "d9",
                                           imageURL: URL(string: "https://e-cdns-images.dzcdn.net/z.jpg")!)
        XCTAssertEqual(only("Air", uncertain: ["air": [fresh]]).candidates, [fresh])
    }

    func testFindSkipsAFreshNotFoundUnlessAskedToLookAgain() throws {
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Air", outcome: .notFound,
                                          checkedAt: now.addingTimeInterval(-86_400)), prepared: nil)
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Beck", outcome: .notFound,
                                          checkedAt: now.addingTimeInterval(-31 * 86_400)), prepared: nil)
        try store.set(ArtistPictureRecord(foldedKey: "", displayName: "Can", outcome: .uncertain, checkedAt: now,
                                          candidates: [ArtistPictureRecord.HeldCandidate(candidate)]), prepared: nil)
        let rows = ArtistPictureRow.rows(artists: [artist("Air"), artist("Beck"), artist("Can"), artist("Dido")],
                                         tree: tree(), store: store, uncertain: [:], now: now)
        let air = try XCTUnwrap(rows.first { $0.name == "Air" })
        XCTAssertEqual(air.state, .none)
        XCTAssertEqual(air.notFoundAt, now.addingTimeInterval(-86_400))
        XCTAssertNil(rows.first { $0.name == "Beck" }?.notFoundAt, "a stale not-found is asked again")

        XCTAssertEqual(Set(ArtistPictureRow.findTargets(rows).map(\.name)), ["Beck", "Can", "Dido"])
        XCTAssertEqual(Set(ArtistPictureRow.findTargets(rows, lookAgain: ["air"]).map(\.name)),
                       ["Air", "Beck", "Can", "Dido"])
    }
}
