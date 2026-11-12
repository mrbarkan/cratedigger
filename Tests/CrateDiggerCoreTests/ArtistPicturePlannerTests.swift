import XCTest
@testable import CrateDiggerCore

/// The planner writes a picture only where the player finds none, never over
/// the owner's, and every plan is applied through the real executor on a
/// FakeIPod whose player files must come out untouched.
final class ArtistPicturePlannerTests: XCTestCase {
    private var iPod: FakeIPod!
    private var before: [String: String]!
    private var journalDir: URL!
    private var journal: DeviceWriteJournal!

    override func setUpWithError() throws {
        iPod = try FakeIPod()
        before = try iPod.manifest()
        journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPicturePlanner-\(UUID().uuidString)", isDirectory: true)
        journal = DeviceWriteJournal(profileID: UUID(), directory: journalDir)
    }

    override func tearDownWithError() throws {
        iPod.assertPlayerStateUntouched(since: before)
        try? FileManager.default.removeItem(at: journalDir)
        iPod = nil
    }

    // MARK: Helpers

    private let picture = Data("prepared picture A".utf8)
    private let otherPicture = Data("prepared picture B, longer".utf8)

    private var executor: DeviceFileExecutor {
        DeviceFileExecutor(volumeRoot: iPod.root, expectedVolumeUUID: "FAKE-UUID",
                           policy: DeviceWritePolicy(musicSubpath: "Music",
                                                     enabledRoles: [.audio, .cover, .temp, .artistPicture,
                                                                    .artistFolderPicture]),
                           journal: journal, volumeUUID: { _ in "FAKE-UUID" }, freeSpace: { _ in 1 << 40 },
                           rootMustBeMountPoint: false)
    }

    private var catalog: [LoadedTrack] = []

    /// An album on the fake device and its tracks in the catalog.
    private func album(_ artist: String, folder: String, category: String? = nil, artistFolder: String? = nil,
                       albumArtist: String? = nil, tracks: Int = 1, cover: Bool = true) throws {
        let url = try iPod.addAlbum(category: category, artist: artistFolder ?? FATName.component(artist, extension: nil)!,
                                    folder: folder, tracks: (1...tracks).map { String(format: "%02d.m4a", $0) },
                                    cover: cover)
        for index in 1...tracks {
            catalog.append(LoadedTrack(
                track: AudioTrack(fileURL: url.appendingPathComponent(String(format: "%02d.m4a", index)),
                                  title: "t", artist: artist, album: folder),
                metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist, album: folder)))
        }
    }

    private func tree() -> DeviceArtTree {
        DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music", catalog: catalog)
    }

    private func artists() -> [ArtistOnDevice] { ArtistOnDevice.all(in: catalog, volumeRoot: iPod.root) }

    private func sha(_ path: String) -> String? {
        try? DeviceFileIO.sha256(of: iPod.root.appendingPathComponent(path))
    }

    private func plan(_ prepared: [String: Data], destination: ArtistPictureDestination = .artworkFolder,
                      artists: [ArtistOnDevice]? = nil, tree: DeviceArtTree? = nil) -> ArtistPicturePlan {
        ArtistPicturePlanner.plan(artists: artists ?? self.artists(), tree: tree ?? self.tree(), prepared: prepared,
                                  destination: destination, ownedKeys: { self.journal.ownedRecord(forKey: $0) },
                                  sha256OnDevice: sha)
    }

    @discardableResult
    private func apply(_ plan: ArtistPicturePlan, file: StaticString = #filePath,
                       line: UInt = #line) -> [DeviceFileOutcome] {
        let outcomes = executor.apply(plan.operations, sessionID: UUID())
        XCTAssertTrue(outcomes.allSatisfy { $0 == .written || $0 == .deleted }, "\(outcomes)", file: file, line: line)
        return outcomes
    }

    private func paths(_ plan: ArtistPicturePlan) -> [String] { plan.operations.map(\.relativePath) }

    private func bytes(_ path: String) -> Data? { try? Data(contentsOf: iPod.root.appendingPathComponent(path)) }

    // MARK: Writing

    func testWritesToArtworkPeople() throws {
        try album("Air", folder: "1998 Moon Safari")
        let plan = plan(["air": picture])
        XCTAssertEqual(paths(plan), ["Artwork/People/Air.jpg"])
        guard case let .write(_, role, .data(data), replacesForeign, subject)? = plan.operations.first else {
            return XCTFail("expected a write")
        }
        XCTAssertEqual(role, .artistPicture)
        XCTAssertEqual(data, picture)
        XCTAssertFalse(replacesForeign)
        XCTAssertEqual(subject, String(PodBoxArtName.key("Air")), "the journal learns whose picture it is")
        apply(plan)
        XCTAssertEqual(journal.ownedRecord(forKey: "Artwork/People/Air.jpg")?.subject, String(PodBoxArtName.key("Air")))
        XCTAssertEqual(bytes("Artwork/People/Air.jpg"), picture)
    }

    func testFileNameKeepsThePodBoxKey() throws {
        try album("AC/DC", folder: "1980 Back in Black")
        let plan = plan(["acdc": picture])
        XCTAssertEqual(paths(plan), ["Artwork/People/AC-DC.jpg"])
        apply(plan)
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/AC-DC/1980 Back in Black"],
                                                     tree: tree()), .found("Artwork/People/AC-DC.jpg"))
    }

    /// Review Focus 1.
    func testTwoNamesOneKeyPlanOneFile() throws {
        let both = [ArtistOnDevice(name: "Björk", albumFolders: ["Music/Björk/Post"], trackCount: 3),
                    ArtistOnDevice(name: "Bjork", albumFolders: ["Music/Bjork/Debut"], trackCount: 2)]
        let memory = DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:], foldersWithAudio: [],
                                   artistsByFolder: [:], libraryFolders: [])
        let plan = plan(["bjork": picture], artists: both, tree: memory)
        XCTAssertEqual(paths(plan), ["Artwork/People/Björk.jpg"])
        XCTAssertEqual(plan.alreadyHasPicture, ["Bjork"])

        try album("Björk", folder: "Post", tracks: 2)
        try album("Bjork", folder: "Debut")
        XCTAssertEqual(artists().map(\.name), ["Björk"], "one person, most common spelling")
        XCTAssertEqual(paths(self.plan(["bjork": picture])), ["Artwork/People/Björk.jpg"])
    }

    /// Review Focus 1.
    func testZeroKeyNameIsUnnameable() throws {
        try album("!!!", folder: "Myth Takes", artistFolder: "Chk Chk Chk")
        try album("Hot \u{1F3B8} Band", folder: "Riffs", artistFolder: "Hot Band")
        let found = artists()
        XCTAssertEqual(Set(found.map(\.name)), ["!!!", "Hot \u{1F3B8} Band"])
        let plan = plan([:], artists: found) // unnameable is reported before "no picture yet"
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(Set(plan.unnameable), ["!!!", "Hot \u{1F3B8} Band"])
        XCTAssertEqual(plan.reasons["!!!"], "cannot be named on this player")
    }

    func testVariousArtistsNeverPlanned() throws {
        try album("Beck", folder: "Some Comp", artistFolder: "Compilations", albumArtist: "Various Artists")
        try album("Prince", folder: "Other Comp", artistFolder: "Compilations2", albumArtist: "VARIOUS ARTISTS")
        XCTAssertEqual(artists(), [])
        XCTAssertEqual(plan(["beck": picture, "variousartists": picture, "prince": picture]).operations.count, 0)
    }

    // MARK: Never over the owner's

    /// Review Focus 5.
    func testOwnersPeopleFileBlocksOurs() throws {
        try album("Air", folder: "1998 Moon Safari")
        try album("Frank Herbert", folder: "Dune Readings")
        try iPod.addFile("Artwork/People/Air.png", Data("owner".utf8))
        try iPod.addFile("Artwork/People/Herbert, Frank.jpg", Data("owner".utf8))

        let plan = plan(["air": picture, "frankherbert": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(Set(plan.alreadyHasPicture), ["Air", "Frank Herbert"])
        XCTAssertEqual(plan.reasons["Air"], "the player already shows Artwork/People/Air.png")
        XCTAssertEqual(bytes("Artwork/People/Air.png"), Data("owner".utf8))
    }

    func testOwnersArtistFolderImageBlocksOurs() throws {
        try album("Air", folder: "1998 Moon Safari")
        try iPod.addFile("Music/Air/Folder.JPG", Data("owner".utf8))
        let plan = plan(["air": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.alreadyHasPicture, ["Air"])
        XCTAssertEqual(plan.reasons["Air"], "the player already shows Music/Air/Folder.JPG")
    }

    /// The controller's rule: `.uncertain` is left alone, with its reason.
    func testUncertainLookupIsLeftAloneWithItsReason() throws {
        try album("Air", folder: "1998 Moon Safari")
        try iPod.addFile("Artwork/People/Air.txt", Data("note".utf8))
        let plan = plan(["air": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.uncertain, ["Air"])
        XCTAssertNotNil(plan.reasons["Air"])
    }

    /// Re-review item 2: a track outside the scanned music folder (an
    /// audiobook, a podcast) is ground the simulation never looked at.
    func testTracksOutsideTheMusicFolderAreUncertain() throws {
        try album("Air", folder: "1998 Moon Safari")
        try iPod.addFile("Audiobooks/Air/Talk/01.m4a", Data([0, 0, 0, 0x20]))
        catalog.append(LoadedTrack(track: AudioTrack(fileURL: iPod.root.appendingPathComponent("Audiobooks/Air/Talk/01.m4a"),
                                                     title: "t", artist: "Air"),
                                   metadata: ConversionMetadata(artist: "Air")))
        let plan = plan(["air": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.uncertain, ["Air"])
        XCTAssertTrue(plan.reasons["Air"]?.contains("Audiobooks/Air/Talk") == true)
    }

    func testTrackFolderMissingFromTheDeviceIsUncertain() throws {
        try album("Air", folder: "1998 Moon Safari")
        // Its own folder is named for it, so the player would look in it.
        let ghost = ArtistOnDevice(name: "Air", albumFolders: ["Music/Air 2/Air"], trackCount: 1)
        let plan = plan(["air": picture], artists: [ghost])
        XCTAssertEqual(plan.uncertain, ["Air"])
        XCTAssertEqual(plan.operations.count, 0)
    }

    /// Review Focus 5: ours, edited by the owner on the iPod, is theirs now.
    func testOurPictureEditedOnDeviceIsNotReplaced() throws {
        try album("Air", folder: "1998 Moon Safari")
        apply(plan(["air": picture]))
        try iPod.addFile("Artwork/People/Air.jpg", Data("the owner's own edit".utf8))

        let replan = plan(["air": otherPicture])
        XCTAssertEqual(replan.operations.count, 0)
        XCTAssertEqual(replan.foreign, ["Air"])

        // And the executor would refuse anyway.
        let forced = executor.apply([.write(relativePath: "Artwork/People/Air.jpg", role: .artistPicture,
                                            contents: .data(otherPicture))], sessionID: UUID())
        XCTAssertEqual(forced, [.refusedForeign])
        XCTAssertEqual(bytes("Artwork/People/Air.jpg"), Data("the owner's own edit".utf8))
    }

    func testOurUnchangedPictureIsReplacedWhenThePickChanges() throws {
        try album("Air", folder: "1998 Moon Safari")
        apply(plan(["air": picture]))
        let replan = plan(["air": otherPicture])
        XCTAssertEqual(paths(replan), ["Artwork/People/Air.jpg"])
        apply(replan)
        XCTAssertEqual(bytes("Artwork/People/Air.jpg"), otherPicture)
    }

    func testReplanWithEverythingPresentIsEmpty() throws {
        try album("Air", folder: "1998 Moon Safari")
        try album("AC/DC", folder: "1980 Back in Black")
        try album("Weezer", folder: "1994 Weezer", artistFolder: "Weezer")
        let prepared = ["air": picture, "acdc": otherPicture, "weezer": picture]
        apply(plan(prepared))
        let replan = plan(prepared)
        XCTAssertEqual(replan.operations.count, 0)
        XCTAssertEqual(Set(replan.alreadyHasPicture), ["Air", "AC/DC", "Weezer"])
        XCTAssertEqual(replan.reasons["Air"], "CrateDigger's picture is already on the iPod")
    }

    func testOffPlansNothing() throws {
        try album("Air", folder: "1998 Moon Safari")
        let plan = plan(["air": picture], destination: .off)
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.noPictureYet, ["Air"])
    }

    func testNoPreparedPictureIsNoPictureYet() throws {
        try album("Air", folder: "1998 Moon Safari")
        XCTAssertEqual(plan([:]).noPictureYet, ["Air"])
    }

    // MARK: Budget and artist folders

    /// In memory: 1,899 owner files in /Artwork/People, room for one more.
    private func crowdedTree(extraImages: [String: [String]] = [:]) -> DeviceArtTree {
        let owners = (1...1_899).map { String(format: "Owner %04d.jpg", $0) }
        return DeviceArtTree(
            peopleFiles: owners, coverFiles: [], folderImages: extraImages,
            foldersWithAudio: ["Music/Ay/A1", "Music/Bee/B1", "Music/Mixed/C1", "Music/Mixed/D1"],
            artistsByFolder: ["Music/Bee": ["bee"], "Music/Mixed": ["cee", "dee"], "Music/Ay": ["ay"]],
            libraryFolders: ["Music"], musicFolder: "Music")
    }

    func testBudgetOverflowGoesToArtistFolderThenReports() {
        let three = [ArtistOnDevice(name: "Ay", albumFolders: ["Music/Ay/A1"], trackCount: 9),
                     ArtistOnDevice(name: "Bee", albumFolders: ["Music/Bee/B1"], trackCount: 5),
                     ArtistOnDevice(name: "Cee", albumFolders: ["Music/Mixed/C1"], trackCount: 1)]
        let plan = plan(["ay": picture, "bee": picture, "cee": picture], artists: three, tree: crowdedTree())
        XCTAssertEqual(paths(plan), ["Artwork/People/Ay.jpg", "Music/Bee/folder.jpg"])
        guard case let .write(_, role, _, _, _)? = plan.operations.last else { return XCTFail("no write") }
        XCTAssertEqual(role, .artistFolderPicture)
        XCTAssertEqual(plan.overBudget, ["Cee"])
    }

    func testOrderIsMostTracksFirstUnderBudget() {
        let two = [ArtistOnDevice(name: "Cee", albumFolders: ["Music/Mixed/C1"], trackCount: 1),
                   ArtistOnDevice(name: "Dee", albumFolders: ["Music/Mixed/D1"], trackCount: 40)]
        let plan = plan(["cee": picture, "dee": picture], artists: two, tree: crowdedTree())
        XCTAssertEqual(paths(plan), ["Artwork/People/Dee.jpg"])
        XCTAssertEqual(plan.overBudget, ["Cee"])
    }

    func testArtistFoldersModeWritesFolderJpgThroughTheExecutor() throws {
        try album("Air", folder: "1998 Moon Safari", cover: false)
        let plan = plan(["air": picture], destination: .artistFolders)
        XCTAssertEqual(paths(plan), ["Music/Air/folder.jpg"])
        apply(plan)
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Air", albumFolders: ["Music/Air/1998 Moon Safari"],
                                                     tree: tree()), .found("Music/Air/folder.jpg"))
    }

    func testArtistFoldersModeFallsBackToPeopleUnderACategoryOfMany() throws {
        // Albums straight in a category folder shared with another artist.
        try album("Air", folder: "1998 Moon Safari", artistFolder: "Electronic")
        try album("Daft Punk", folder: "2001 Discovery", artistFolder: "Electronic")
        let plan = plan(["air": picture, "daftpunk": otherPicture], destination: .artistFolders)
        XCTAssertEqual(paths(plan), ["Artwork/People/Air.jpg", "Artwork/People/Daft Punk.jpg"])
        apply(plan)
    }

    func testArtistFolderWithExistingImageIsNotUsed() throws {
        try album("Air", folder: "1998 Moon Safari", cover: false)
        try iPod.addFile("Music/Air/cover.png", Data("owner".utf8))
        let plan = plan(["air": picture], destination: .artistFolders)
        XCTAssertEqual(plan.operations.count, 0, "the owner's own image is the portrait already")
        XCTAssertEqual(plan.alreadyHasPicture, ["Air"])
    }

    /// A disc folder's parent is the album: never the artist folder.
    func testDiscFolderAlbumIsNotMistakenForTheArtistFolder() throws {
        try album("Weezer", folder: "CD1", artistFolder: "Weezer/Weezer", cover: false)
        let plan = plan(["weezer": picture], destination: .artistFolders)
        XCTAssertEqual(paths(plan), ["Music/Weezer/folder.jpg"])
    }

    // MARK: Removal

    func testRemovalPlanOnlyOwnedAndUnedited() throws {
        try album("Air", folder: "1998 Moon Safari")
        try album("Beck", folder: "1996 Odelay")
        try album("Weezer", folder: "1994 Blue", cover: false)
        apply(plan(["air": picture, "beck": picture]))
        apply(plan(["weezer": picture], destination: .artistFolders))
        try iPod.addFile("Artwork/People/Beck.jpg", Data("the owner's edit".utf8))

        let removals = ArtistPicturePlanner.removalPlan(journalRecords: journal.records, volumeUUID: "FAKE-UUID",
                                                        sha256OnDevice: sha)
        XCTAssertEqual(removals.map(\.relativePath), ["Artwork/People/Air.jpg", "Music/Weezer/folder.jpg"])
        let outcomes = executor.apply(removals, sessionID: UUID())
        XCTAssertEqual(outcomes, [.deleted, .deleted])
        XCTAssertNil(bytes("Artwork/People/Air.jpg"))
        XCTAssertEqual(bytes("Artwork/People/Beck.jpg"), Data("the owner's edit".utf8))
        XCTAssertNotNil(bytes("Music/Air/1998 Moon Safari/cover.jpg"), "covers are never in a picture removal")

        XCTAssertEqual(ArtistPicturePlanner.removalPlan(journalRecords: journal.records, volumeUUID: "FAKE-UUID",
                                                        sha256OnDevice: sha).count, 0,
                       "a removed picture is not removed twice")
    }

    /// The sheet's Remove from iPod: one artist, only CrateDigger's own
    /// unchanged picture for that person.
    func testRemovalOfOneArtistNeedsTheJournalsProofForThatPerson() throws {
        try album("Air", folder: "1998 Moon Safari")
        try album("Beck", folder: "1996 Odelay")
        apply(plan(["air": picture, "beck": picture]))
        try iPod.addFile("Artwork/People/Beck.jpg", Data("the owner's edit".utf8))
        try iPod.addFile("Artwork/People/Can.jpg", Data("the owner's own".utf8))
        let owned = { (path: String) in self.journal.ownedRecord(forKey: path, volumeUUID: "FAKE-UUID") }

        let air = try XCTUnwrap(ArtistPicturePlanner.removal(of: "Artwork/People/Air.jpg", forArtist: "Air",
                                                              ownedKeys: owned, sha256OnDevice: sha))
        XCTAssertNil(ArtistPicturePlanner.removal(of: "Artwork/People/Air.jpg", forArtist: "Beck",
                                                  ownedKeys: owned, sha256OnDevice: sha), "another person's")
        XCTAssertNil(ArtistPicturePlanner.removal(of: "Artwork/People/Beck.jpg", forArtist: "Beck",
                                                  ownedKeys: owned, sha256OnDevice: sha), "edited on the iPod")
        XCTAssertNil(ArtistPicturePlanner.removal(of: "Artwork/People/Can.jpg", forArtist: "Can",
                                                  ownedKeys: owned, sha256OnDevice: sha), "the owner's")
        XCTAssertNil(ArtistPicturePlanner.removal(of: "Music/Air/1998 Moon Safari/cover.jpg", forArtist: "Air",
                                                  ownedKeys: owned, sha256OnDevice: sha), "never a cover")

        let session = UUID()
        XCTAssertEqual(executor.apply([air], sessionID: session), [.deleted])
        XCTAssertNil(bytes("Artwork/People/Air.jpg"))
        XCTAssertEqual(bytes("Artwork/People/Beck.jpg"), Data("the owner's edit".utf8))
        let copies = try XCTUnwrap(journal.backupFolderIfUsed(sessionID: session), "backed up first")
        XCTAssertEqual(try Data(contentsOf: copies.appendingPathComponent("Artwork/People/Air.jpg")), picture)
    }

    // MARK: Review fixes

    /// I1: a picture CrateDigger wrote for Prince is never handed to
    /// "Prince and the Revolution", whose album the player also leads there.
    func testPrinceAndTheRevolutionNeverTradeAFolderPicture() throws {
        try album("Prince", folder: "1982 1999", cover: false)
        let first = plan(["prince": picture], destination: .artistFolders)
        XCTAssertEqual(paths(first), ["Music/Prince/folder.jpg"])
        apply(first)

        try album("Prince and the Revolution", folder: "1984 Purple Rain", artistFolder: "Prince", cover: false)
        let prepared = ["prince": picture, PodBoxArtName.folded("Prince and the Revolution"): otherPicture]
        for round in 1...2 {
            let replan = plan(prepared, destination: .artistFolders)
            XCTAssertEqual(replan.operations.count, 0, "round \(round)")
            XCTAssertEqual(Set(replan.alreadyHasPicture), ["Prince", "Prince and the Revolution"], "round \(round)")
            XCTAssertEqual(replan.reasons["Prince and the Revolution"],
                           "the player already shows Music/Prince/folder.jpg, CrateDigger's picture for another artist")
            apply(replan)
        }
        XCTAssertEqual(bytes("Music/Prince/folder.jpg"), picture)
    }

    /// I1: two people the player leads to one file in one plan: one write.
    func testOnePathIsWrittenOnce() {
        let memory = DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:],
                                   foldersWithAudio: ["Music/Prince/1982 1999", "Music/Prince/1984 Purple Rain"],
                                   artistsByFolder: ["Music/Prince": ["prince"]], libraryFolders: [], musicFolder: "Music")
        let two = [ArtistOnDevice(name: "Prince", albumFolders: ["Music/Prince/1982 1999"], trackCount: 9),
                   ArtistOnDevice(name: "Prince and the Revolution", albumFolders: ["Music/Prince/1984 Purple Rain"],
                                  trackCount: 1)]
        let plan = plan(["prince": picture, PodBoxArtName.folded("Prince and the Revolution"): otherPicture],
                        destination: .artistFolders, artists: two, tree: memory)
        XCTAssertEqual(paths(plan), ["Music/Prince/folder.jpg"])
        XCTAssertEqual(plan.alreadyHasPicture, ["Prince and the Revolution"])
    }

    /// M2: a transfer's cover.jpg the player takes as the portrait is not a
    /// picture CrateDigger may replace.
    func testATransferCoverIsNeverReplaced() throws {
        try album("Air", folder: "Moon Safari", artistFolder: "Air", cover: false)
        // Tracks straight in the folder named for the artist: its cover is the portrait.
        try iPod.addFile("Music/Air/01.m4a", Data([0, 0, 0, 0x20]))
        catalog.append(LoadedTrack(track: AudioTrack(fileURL: iPod.root.appendingPathComponent("Music/Air/01.m4a"),
                                                     title: "t", artist: "Air"),
                                   metadata: ConversionMetadata(artist: "Air")))
        XCTAssertEqual(executor.apply([.write(relativePath: "Music/Air/cover.jpg", role: .cover,
                                              contents: .data(Data("cover".utf8)))], sessionID: UUID()), [.written])
        let plan = plan(["air": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.reasons["Air"], "the player already shows Music/Air/cover.jpg")
    }

    /// I2: a catalog that no longer matches the device plans nothing.
    func testStaleCatalogRefusesToPlan() throws {
        try album("Air", folder: "1998 Moon Safari")
        try iPod.addFile("Music/Air/2004 Talkie Walkie/01.m4a", Data([0, 0, 0, 0x20])) // not in the catalog
        let plan = plan(["air": picture])
        XCTAssertEqual(plan.operations.count, 0)
        XCTAssertEqual(plan.refusal, "The device catalog does not match what is on the iPod "
                       + "(Music/Air/2004 Talkie Walkie). Rescan the device first.", "names the folder")
        XCTAssertEqual(plan.uncertain, ["Air"])
        XCTAssertEqual(tree().catalogMismatch, ["Music/Air/2004 Talkie Walkie"])

        catalog.append(LoadedTrack(track: AudioTrack(fileURL: iPod.root.appendingPathComponent("Music/Gone/01.m4a"),
                                                     title: "t", artist: "Gone"),
                                   metadata: ConversionMetadata(artist: "Gone")))
        XCTAssertEqual(tree().catalogMismatch, ["Music/Air/2004 Talkie Walkie", "Music/Gone"],
                       "a catalog track with nothing on the device counts too")
    }

    /// The catalog is compared with what its scanner reads: audio with the
    /// hidden flag (FAT's hidden attribute) or in a hidden folder is never
    /// scanned, so it cannot make the catalog read as stale for good; a
    /// symlinked track the scanner did take is not "missing" either.
    func testFilesTheScannerNeverReadsDoNotMakeTheCatalogStale() throws {
        try album("Air", folder: "1998 Moon Safari")
        let hiddenFile = try iPod.addFile("Music/Air/Hidden Single/01.m4a", Data([0, 0, 0, 0x20]))
        XCTAssertEqual(chflags(hiddenFile.path, UInt32(UF_HIDDEN)), 0)
        let hiddenFolder = iPod.root.appendingPathComponent("Music/Air/Secret", isDirectory: true)
        try iPod.addFile("Music/Air/Secret/Inner/01.m4a", Data([0, 0, 0, 0x20]))
        XCTAssertEqual(chflags(hiddenFolder.path, UInt32(UF_HIDDEN)), 0)
        let target = try iPod.addFile("Elsewhere/song.m4a", Data([0, 0, 0, 0x20]))
        let link = iPod.root.appendingPathComponent("Music/Air/Linked/01.m4a")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        catalog.append(LoadedTrack(track: AudioTrack(fileURL: link, title: "t", artist: "Air"),
                                   metadata: ConversionMetadata(artist: "Air")))

        XCTAssertEqual(tree().catalogMismatch, [])
        XCTAssertNil(plan(["air": picture]).refusal)
    }

    func testRescanRefusalNamesAtMostThreeFolders() {
        XCTAssertEqual(ArtistPicturePlanner.rescanRefusal(folders: []), ArtistPicturePlanner.rescanFirst)
        XCTAssertEqual(ArtistPicturePlanner.rescanRefusal(folders: ["a", "b", "c", "d", "e"]),
                       "The device catalog does not match what is on the iPod (a, b, c and 2 more). Rescan the device first.")
    }

    /// M9: a second spelling follows the first spelling's reason, not a
    /// claim that a picture is shared.
    func testSecondSpellingFollowsAHeldFirst() throws {
        try album("Air", folder: "1998 Moon Safari")
        try iPod.addFile("Artwork/People/Air.txt", Data("note".utf8))
        let two = [ArtistOnDevice(name: "Air", albumFolders: ["Music/Air/1998 Moon Safari"], trackCount: 5),
                   ArtistOnDevice(name: "AIR", albumFolders: ["Music/Air/1998 Moon Safari"], trackCount: 1)]
        let plan = plan(["air": picture], artists: two)
        XCTAssertEqual(plan.uncertain, ["Air", "AIR"])
        XCTAssertTrue(plan.reasons["AIR"]?.hasPrefix("same person as Air: ") == true)
    }

    /// M8: records written on another volume are not removed here.
    func testRemovalPlanMatchesTheVolume() throws {
        try album("Air", folder: "1998 Moon Safari")
        apply(plan(["air": picture]))
        XCTAssertEqual(ArtistPicturePlanner.removalPlan(journalRecords: journal.records, volumeUUID: "OTHER-UUID",
                                                        sha256OnDevice: sha).count, 0)
        XCTAssertEqual(ArtistPicturePlanner.removalPlan(journalRecords: journal.records, volumeUUID: "FAKE-UUID",
                                                        sha256OnDevice: sha).count, 1)
    }

    // MARK: Artists on the device

    func testArtistsOnDeviceGroupsSpellingsByKey() throws {
        try album("The Beatles", folder: "1965 Help", artistFolder: "Beatles", tracks: 2)
        try album("Beatles", folder: "1969 Abbey Road", artistFolder: "Beatles")
        try album("Beatles, The", folder: "1966 Revolver", artistFolder: "Beatles")
        try album("Frank Herbert", folder: "Dune", tracks: 2)
        try album("Herbert, Frank", folder: "Children of Dune", artistFolder: "Frank Herbert")
        try album("Air", folder: "1998 Moon Safari", tracks: 7)
        try album("Beck", folder: "1996 Odelay", artistFolder: "Comp", albumArtist: "Various Artists")

        let found = artists()
        XCTAssertEqual(found.map(\.name), ["Air", "The Beatles", "Frank Herbert"])
        XCTAssertEqual(found.map(\.trackCount), [7, 4, 3])
        let beatles = found[1]
        XCTAssertEqual(beatles.foldedKey, "beatles")
        XCTAssertEqual(beatles.albumFolders, ["Music/Beatles/1965 Help", "Music/Beatles/1966 Revolver",
                                              "Music/Beatles/1969 Abbey Road"])
        XCTAssertEqual(beatles.albumTitles, ["1965 Help", "1966 Revolver", "1969 Abbey Road"])
    }
}
