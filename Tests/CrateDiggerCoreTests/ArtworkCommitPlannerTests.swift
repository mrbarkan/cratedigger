import XCTest
@testable import CrateDiggerCore

final class ArtworkCommitPlannerTests: XCTestCase {

    func testNothingPendingIsAnEmptyPlan() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg"], staged: [],
                                             removals: [], stripEmbedded: false)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.changeCount, 0)
    }

    /// The commonest edit there is: a new cover for an album that has one.
    /// Marking the old one for removal frees its name, so the replacement
    /// keeps `cover.jpg` rather than becoming `cover_2.jpg`.
    func testReplacingTheCoverReusesItsName() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg", "back.jpg"],
                                             staged: ["cover.jpg"],
                                             removals: ["cover.jpg"],
                                             stripEmbedded: false)
        XCTAssertEqual(plan.trash, ["cover.jpg"])
        XCTAssertEqual(plan.writes, [.init(stagedName: "cover.jpg", finalName: "cover.jpg")])
    }

    /// Keeping the old one instead must not silently overwrite it.
    func testStagedFileNeverClobbersAFileYouAreKeeping() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg"],
                                             staged: ["cover.jpg"],
                                             removals: [],
                                             stripEmbedded: false)
        XCTAssertTrue(plan.trash.isEmpty)
        XCTAssertEqual(plan.writes, [.init(stagedName: "cover.jpg", finalName: "cover_2.jpg")])
    }

    /// Two staged files wanting the same name is the same hazard, inside one
    /// batch rather than against the folder.
    func testTwoStagedFilesCannotClaimTheSameName() {
        let plan = ArtworkCommitPlanner.plan(existing: [],
                                             staged: ["booklet.jpg", "booklet.jpg"],
                                             removals: [],
                                             stripEmbedded: false)
        XCTAssertEqual(plan.writes.map(\.finalName), ["booklet.jpg", "booklet_2.jpg"])
    }

    func testUniqueNamesKeepCountingPastTheSecond() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg", "cover_2.jpg"],
                                             staged: ["cover.jpg"],
                                             removals: [],
                                             stripEmbedded: false)
        XCTAssertEqual(plan.writes.first?.finalName, "cover_3.jpg")
    }

    /// A removal for something already gone is intent that already holds, not
    /// a failure — the plan just has nothing to do for it.
    func testRemovalOfAVanishedFileIsDropped() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg"],
                                             staged: [],
                                             removals: ["back.jpg"],
                                             stripEmbedded: false)
        XCTAssertTrue(plan.trash.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    func testStripEmbeddedCountsAsAChangeOnItsOwn() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg"], staged: [],
                                             removals: [], stripEmbedded: true)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.changeCount, 1)
    }

    func testChangeCountAddsUpAcrossAllThreeKinds() {
        let plan = ArtworkCommitPlanner.plan(existing: ["cover.jpg", "back.jpg"],
                                             staged: ["disc.jpg"],
                                             removals: ["back.jpg"],
                                             stripEmbedded: true)
        XCTAssertEqual(plan.changeCount, 3)
    }

    /// Files without an extension still get a distinct name.
    func testExtensionlessNamesStillDeduplicate() {
        XCTAssertEqual(ArtworkCommitPlanner.uniqueName(for: "scan", avoiding: ["scan"]), "scan_2")
    }

    // MARK: - Staging

    func testStagingFolderIsStablePerAlbumAndDistinctBetweenAlbums() {
        let a = URL(fileURLWithPath: "/Music/Air/Moon Safari")
        let b = URL(fileURLWithPath: "/Music/Air/Premiers Symptomes")
        XCTAssertEqual(ArtworkStaging.folder(forAlbumFolder: a),
                       ArtworkStaging.folder(forAlbumFolder: a))
        XCTAssertNotEqual(ArtworkStaging.folder(forAlbumFolder: a),
                          ArtworkStaging.folder(forAlbumFolder: b))
    }

    /// Two albums of the same name under different artists must not share a
    /// staging folder — that would cross-contaminate pending imports.
    func testSameLeafNameUnderDifferentParentsStaysSeparate() {
        let a = URL(fileURLWithPath: "/Music/Air/Greatest Hits")
        let b = URL(fileURLWithPath: "/Music/Björk/Greatest Hits")
        XCTAssertNotEqual(ArtworkStaging.key(for: a), ArtworkStaging.key(for: b))
    }

    // MARK: - Stripping

    /// The flags that matter: audio mapped, nothing re-encoded, video dropped.
    func testStripArtworkArgumentsKeepAudioAndDropPictures() {
        let args = MetadataEditorService.stripArtworkArguments(
            input: URL(fileURLWithPath: "/Music/a.flac"),
            output: URL(fileURLWithPath: "/Music/tmp.flac")
        )
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertEqual(args.firstIndex(of: "-map").map { args[$0 + 1] }, "0:a")
        XCTAssertEqual(args.firstIndex(of: "-c").map { args[$0 + 1] }, "copy")
        XCTAssertEqual(args.firstIndex(of: "-map_metadata").map { args[$0 + 1] }, "0")
        XCTAssertEqual(args.last, "/Music/tmp.flac")
    }

    func testStripArtworkPinsID3v2VersionForMP3() {
        let args = MetadataEditorService.stripArtworkArguments(
            input: URL(fileURLWithPath: "/Music/a.mp3"),
            output: URL(fileURLWithPath: "/Music/tmp.mp3")
        )
        XCTAssertEqual(args.firstIndex(of: "-id3v2_version").map { args[$0 + 1] }, "3")
    }
}

final class ArtworkStagingSweepTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cd-sweep-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// Builds a session folder; `albumFolderPath` nil means "album still there".
    private func makeSession(named name: String,
                             images: [String],
                             albumFolderPath: String?,
                             stripEmbedded: Bool = false,
                             modified: Date = Date()) throws -> URL {
        let session = root.appendingPathComponent(name)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        for image in images {
            let url = session.appendingPathComponent(image)
            try Data([0xFF]).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let info = StagedArtworkInfo(albumFolderPath: albumFolderPath, stripEmbedded: stripEmbedded)
        let infoURL = session.appendingPathComponent("cratedigger-staging.json")
        try JSONEncoder().encode(info).write(to: infoURL)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: infoURL.path)
        return session
    }

    private func sweeps(_ session: URL, now: Date = Date()) -> Bool {
        ArtworkStaging.shouldSweep(session, maxAge: 30 * 24 * 60 * 60, now: now, fileManager: fm)
    }

    func testKeepsALiveSession() throws {
        let session = try makeSession(named: "live", images: ["cover.jpg"],
                                      albumFolderPath: root.path)
        XCTAssertFalse(sweeps(session))
    }

    /// The album moved or was deleted: this session can never be committed.
    func testSweepsSessionWhoseAlbumIsGone() throws {
        let session = try makeSession(named: "orphan", images: ["cover.jpg"],
                                      albumFolderPath: "/nowhere/at/all")
        XCTAssertTrue(sweeps(session))
    }

    func testSweepsEmptyFolder() throws {
        let session = root.appendingPathComponent("empty")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        XCTAssertTrue(sweeps(session))
    }

    /// A sidecar with no images and nothing marked is a leftover, not a session.
    func testSweepsIdleSidecarWithNoImages() throws {
        let session = try makeSession(named: "idle", images: [], albumFolderPath: root.path)
        XCTAssertTrue(sweeps(session))
    }

    /// …but a mark with no images is real intent, and must survive.
    func testKeepsMarksEvenWithNoStagedImages() throws {
        let session = try makeSession(named: "marks", images: [],
                                      albumFolderPath: root.path, stripEmbedded: true)
        XCTAssertFalse(sweeps(session))
    }

    func testSweepsSessionUntouchedForLongerThanMaxAge() throws {
        let old = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let session = try makeSession(named: "stale", images: ["cover.jpg"],
                                      albumFolderPath: root.path, modified: old)
        XCTAssertTrue(sweeps(session))
    }

    func testKeepsSessionInsideMaxAge() throws {
        let recent = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let session = try makeSession(named: "recent", images: ["cover.jpg"],
                                      albumFolderPath: root.path, modified: recent)
        XCTAssertFalse(sweeps(session))
    }

    /// A session written before `albumFolderPath` existed has no path to check;
    /// it must fall through to the age rule rather than being deleted outright.
    func testLegacySessionWithoutAlbumPathIsJudgedByAgeAlone() throws {
        let session = try makeSession(named: "legacy", images: ["cover.jpg"],
                                      albumFolderPath: nil)
        XCTAssertFalse(sweeps(session))
    }
}
