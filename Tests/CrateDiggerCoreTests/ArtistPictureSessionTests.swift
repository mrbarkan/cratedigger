import XCTest
@testable import CrateDiggerCore

/// The decisions around one artist-picture run: when it may write, which
/// names it looks up, what it stores, and the line the summary gets.
final class ArtistPictureSessionTests: XCTestCase {
    private var folder: URL!
    private var store: ArtistProfileStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPictureSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ArtistProfileStore(indexDirectory: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func inputs(destination: ArtistPictureDestination = .artworkFolder, automatic: Bool = true,
                        matchedByUUID: Bool = true, hasCapability: Bool = true, passedM5: Bool = true,
                        artists: [ArtistOnDevice] = [], tree: DeviceArtTree? = nil) -> ArtistPictureSession.Inputs {
        ArtistPictureSession.Inputs(artists: artists, tree: tree, destination: destination, automatic: automatic,
                                    matchedByUUID: matchedByUUID, hasCapability: hasCapability, passedM5: passedM5)
    }

    private func artist(_ name: String) -> ArtistOnDevice {
        ArtistOnDevice(name: name, albumFolders: ["Music/\(name)/2000 Album"], albumTitles: ["Album"], trackCount: 3)
    }

    private func tree(peopleFiles: [String] = [], folderImages: [String: [String]] = [:],
                      mismatch: [String] = []) -> DeviceArtTree {
        DeviceArtTree(peopleFiles: peopleFiles, coverFiles: [], folderImages: folderImages,
                      foldersWithAudio: [], artistsByFolder: [:], catalogMismatch: mismatch)
    }

    private func plan(alreadyHas: [String] = [], noPicture: [String] = [], overBudget: [String] = [],
                      foreign: [String] = [], refusal: String? = nil) -> ArtistPicturePlan {
        ArtistPicturePlan(operations: [], alreadyHasPicture: alreadyHas, noPictureYet: noPicture, overBudget: overBudget,
                          unnameable: [], foreign: foreign, uncertain: [], reasons: [:], refusal: refusal)
    }

    // MARK: mayWrite

    func testMayWriteReasonsInOrder() {
        let session = ArtistPictureSession.self
        XCTAssertEqual(session.mayWrite(inputs(destination: .off, hasCapability: false), trigger: .userAction).reason,
                       "Artist pictures are off for this device.")
        XCTAssertEqual(session.mayWrite(inputs(matchedByUUID: false, hasCapability: false), trigger: .userAction).reason,
                       "This device is not PodBox.")
        XCTAssertEqual(session.mayWrite(inputs(matchedByUUID: false, passedM5: false), trigger: .userAction).reason,
                       "Artist pictures need a device matched by its volume ID.")
        XCTAssertEqual(session.mayWrite(inputs(passedM5: false), trigger: .userAction).reason,
                       "Artist pictures wait for the M5 check on this iPod.")
        let allowed = session.mayWrite(inputs(), trigger: .userAction)
        XCTAssertTrue(allowed.allowed)
        XCTAssertNil(allowed.reason)
        XCTAssertTrue(session.mayWrite(inputs(destination: .artistFolders), trigger: .userAction).allowed)
    }

    func testTransferNeedsM5ButExplicitActionDoesNot() {
        XCTAssertFalse(ArtistPictureSession.mayWrite(inputs(automatic: true, passedM5: false), trigger: .userAction).allowed)
        XCTAssertTrue(ArtistPictureSession.mayWrite(inputs(automatic: false, passedM5: false), trigger: .userAction).allowed)
        XCTAssertFalse(ArtistPictureSession.mayWrite(inputs(automatic: false, matchedByUUID: false, passedM5: false),
                                                     trigger: .userAction).allowed,
                       "an explicit action still needs the volume ID")
    }

    func testMountNeverWrites() {
        for automatic in [true, false] {
            XCTAssertFalse(ArtistPictureSession.mayWrite(inputs(automatic: automatic), trigger: .mount).allowed)
        }
    }

    // MARK: namesToFind

    @discardableResult
    private func photo(_ name: String, side: Int = 600) throws -> ArtistPhoto {
        let red = CGFloat(name.utf8.reduce(0) { $0 + Int($1) } % 97) / 97
        return try store.addPhoto(name: name, data: FakePictureFetcher.jpeg(width: side, height: side, red: red),
                                  source: .deezer, sourceID: name, credit: nil)
    }

    func testNamesToFindSkipsFreshNotFound() throws {
        store.update(name: "Air") { $0.photoSearchedAt = self.now.addingTimeInterval(-86_400) }
        let names = ArtistPictureSession.namesToFind(inputs(artists: [artist("Air"), artist("Can")], tree: tree()),
                                                     profiles: store, now: now)
        XCTAssertEqual(names.map(\.name), ["Can"])
    }

    func testNamesToFindRetriesStaleNotFound() throws {
        store.update(name: "Air") { $0.photoSearchedAt = self.now.addingTimeInterval(-31 * 86_400) }
        let names = ArtistPictureSession.namesToFind(inputs(artists: [artist("Air")], tree: tree()), profiles: store,
                                                     now: now)
        XCTAssertEqual(names.map(\.name), ["Air"])
    }

    func testNamesToFindSkipsRejectedAndFound() throws {
        // "Don't Send to iPod", a picture ready, candidates waiting for the owner.
        store.update(name: "Air") { $0.notOnIPod = true }
        try photo("Can")
        store.update(name: "Low") { profile in
            profile.photoCandidates = [ArtistPictureRecord.HeldCandidate(
                source: .deezer, sourceID: "1", imageURL: URL(string: "https://e-cdns-images.dzcdn.net/low.jpg")!)]
        }
        // A default photo whose file is gone is looked up again...
        let gone = try photo("Tool")
        try FileManager.default.removeItem(at: store.photoURL(hash: gone.hash))
        // ...unless the owner picked it.
        let picked = try photo("Dido")
        store.setDefault(name: "Dido", hash: picked.hash)
        try FileManager.default.removeItem(at: store.photoURL(hash: picked.hash))
        let names = ArtistPictureSession.namesToFind(
            inputs(artists: ["Air", "Can", "Low", "Tool", "Dido", "Yes"].map(artist), tree: tree()), profiles: store,
            now: now)
        XCTAssertEqual(names.map(\.name), ["Tool", "Yes"])
    }

    func testNamesToFindSkipsArtistsThePlayerAlreadyFinds() {
        let tree = tree(peopleFiles: ["Air.jpg"], folderImages: ["Music/Low": ["folder.jpg"]])
        let names = ArtistPictureSession.namesToFind(
            inputs(artists: [artist("Air"), artist("Low"), artist("Can"), artist("!!!")], tree: tree),
            profiles: store, now: now)
        XCTAssertEqual(names.map(\.name), ["Can"], "the owner's People file, a named folder's image, an unnameable name")
        XCTAssertEqual(ArtistPictureSession.namesToFind(inputs(artists: [artist("Can")], tree: self.tree(mismatch: ["x"])),
                                                        profiles: store, now: now), [],
                       "a catalog that does not match the device is not looked up against")
    }

    // MARK: Keeping what a search found

    func testFoundPictureBecomesTheDefaultPhoto() throws {
        let original = FakePictureFetcher.jpeg(width: 900, height: 900)
        let prepared = try XCTUnwrap(ArtistPictureImage.prepare(original))
        let credit = ArtistPictureCredit(fileName: "Air.jpg", licence: "CC BY-SA 4.0", author: "Someone")
        let candidate = ArtistPictureCandidate(name: "Air", source: .commons, sourceID: "Q123",
                                               imageURL: URL(string: "https://upload.wikimedia.org/a.jpg")!,
                                               credit: credit)
        let finding = ArtistPictureFinding(name: "Air", outcome: .found(prepared: prepared, candidate: candidate,
                                                                        source: .commons),
                                           original: original, originalURL: candidate.imageURL)
        XCTAssertEqual(ArtistPictureSession.store([finding], in: store, now: now), 1)

        let profile = try XCTUnwrap(store.profile(forName: "Air"))
        let photo = try XCTUnwrap(profile.defaultPhotoRef)
        XCTAssertEqual(photo.source, .commons)
        XCTAssertEqual(photo.sourceID, "Q123")
        XCTAssertEqual(photo.credit, credit)
        XCTAssertEqual(photo.pixelWidth, 900, "the full-size original, not the iPod's 400 px copy")
        XCTAssertFalse(profile.defaultPickedByOwner)
        XCTAssertNotNil(ArtistPictureSession.prepared(for: [artist("Air")], profiles: store)["air"],
                        "the planner agrees")

        // A second find never moves the default, and nothing lands under
        // "no photo" or from a source the owner removed.
        let other = FakePictureFetcher.jpeg(width: 700, height: 700, red: 0.1)
        let again = ArtistPictureFinding(
            name: "Air", outcome: .found(prepared: try XCTUnwrap(ArtistPictureImage.prepare(other)), candidate: nil,
                                         source: .libraryFolder),
            original: other, originalURL: URL(fileURLWithPath: "/Music/Air/artist.jpg"))
        ArtistPictureSession.store([again], in: store, now: now)
        XCTAssertEqual(store.profile(forName: "Air")?.defaultPhoto, photo.hash)
        XCTAssertEqual(store.profile(forName: "Air")?.photos.last?.sourceID, "/Music/Air/artist.jpg")

        store.update(name: "Can") { $0.noPhoto = true }
        store.update(name: "Low") { $0.rejectedPhotoSources = ["commons:Q123"] }
        for name in ["Can", "Low"] {
            let finding = ArtistPictureFinding(name: name, outcome: .found(prepared: prepared, candidate: candidate,
                                                                           source: .commons), original: original)
            XCTAssertEqual(ArtistPictureSession.store([finding], in: store, now: now), 0)
            XCTAssertEqual(store.profile(forName: name)?.photos, [], name)
        }
    }

    func testUncertainFindingHoldsCandidatesOnly() throws {
        let candidate = ArtistPictureCandidate(name: "Air", source: .deezer, sourceID: "1",
                                               imageURL: URL(string: "https://e-cdns-images.dzcdn.net/a.jpg")!)
        ArtistPictureSession.store([ArtistPictureFinding(name: "Air", outcome: .uncertain([candidate]))], in: store,
                                   now: now)
        let profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(profile.photos, [], "no image is kept for an uncertain match")
        XCTAssertEqual(profile.photoCandidates, [ArtistPictureRecord.HeldCandidate(candidate)],
                       "the candidates are held with the profile, not only in the sheet")

        XCTAssertEqual(ArtistPictureSession.store([ArtistPictureFinding(name: "Can", outcome: .failed("offline"))],
                                                  in: store, now: now), 0)
        XCTAssertNil(store.profile(forName: "Can"), "a failure is never stored")

        ArtistPictureSession.store([ArtistPictureFinding(name: "Low", outcome: .notFound)], in: store, now: now)
        XCTAssertEqual(store.profile(forName: "Low")?.photoSearchedAt, now)
        XCTAssertNil(store.profile(forName: "Low")?.checkedAt, "a picture search is not the lookup's cursor")
    }

    // MARK: summaryLine

    func testSummaryLineVariants() {
        let session = ArtistPictureSession.self
        XCTAssertNil(session.summaryLine(written: 0, plan: plan()))
        XCTAssertNil(session.summaryLine(written: 0, plan: plan(alreadyHas: ["Air"])))
        XCTAssertEqual(session.summaryLine(written: 1, plan: plan()), "Wrote 1 artist picture.")
        XCTAssertEqual(session.summaryLine(written: 3, plan: plan(alreadyHas: ["A", "B"], foreign: ["C"])),
                       "Wrote 3 artist pictures, 3 already had one.")
        XCTAssertEqual(session.summaryLine(written: 0, plan: plan(noPicture: ["A", "B"])),
                       "Wrote 0 artist pictures, 2 waiting for a pick.")
        XCTAssertEqual(session.summaryLine(written: 2, plan: plan(alreadyHas: ["A"], noPicture: ["B"], overBudget: ["C"])),
                       "Wrote 2 artist pictures, 1 already had one, 1 waiting for a pick, 1 did not fit.")
        XCTAssertEqual(session.summaryLine(written: 0, plan: plan(refusal: "Rescan the device first.")),
                       "Rescan the device first.", "a refused plan says why")
    }

    func testSummaryLineHasNoEmDash() {
        let lines = [
            ArtistPictureSession.summaryLine(written: 2, plan: plan(alreadyHas: ["A"], noPicture: ["B"], overBudget: ["C"])),
            ArtistPictureSession.picturesOff, ArtistPictureSession.notPodBox, ArtistPictureSession.needsVolumeID,
            ArtistPictureSession.waitsForM5, ArtistPictureSession.notAtMount, ArtistPictureSession.artCacheReminder,
            ArtistPicturePlanner.rescanRefusal(folders: ["a", "b", "c", "d"]),
        ].compactMap { $0 }
        for line in lines { XCTAssertFalse(line.contains("\u{2014}"), line) }
    }

    // MARK: Reminder and library

    func testArtCacheReminderOnlyForCoversOrPicturesOnPodBox() {
        let podBox = DeviceFirmware(flavour: .podBox, layout: 5, build: nil)
        let stock = DeviceFirmware(flavour: .stockRockbox, layout: nil, build: nil)
        XCTAssertTrue(ArtistPictureSession.remindsToUpdateArtCache(changes: [.pictures], firmware: podBox))
        XCTAssertTrue(ArtistPictureSession.remindsToUpdateArtCache(changes: [.audio, .covers], firmware: podBox))
        XCTAssertFalse(ArtistPictureSession.remindsToUpdateArtCache(changes: [.audio], firmware: podBox))
        XCTAssertFalse(ArtistPictureSession.remindsToUpdateArtCache(changes: [.pictures], firmware: stock))
        XCTAssertFalse(ArtistPictureSession.remindsToUpdateArtCache(changes: [.pictures], firmware: nil))
    }

    func testLibraryPictureIsTheOwnersArtistJpg() throws {
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        let album = library.appendingPathComponent("Air/1998 Moon Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("not decoded here".utf8).write(to: library.appendingPathComponent("Air/artist.jpg"))
        let track = LoadedTrack(track: AudioTrack(fileURL: album.appendingPathComponent("01.flac"), title: "t",
                                                  artist: "Air", album: "Moon Safari"),
                                metadata: ConversionMetadata(artist: "Air", album: "Moon Safari"))
        let folders = ArtistPictureSession.LibraryFolders(tracks: [track])
        XCTAssertEqual(folders.picture(for: "Air")?.lastPathComponent, "artist.jpg")
        XCTAssertNil(folders.picture(for: "Can"))
        let requests = ArtistPictureSession.requests(for: [artist("Air")], library: folders)
        XCTAssertEqual(requests.first?.libraryPicture?.lastPathComponent, "artist.jpg")
    }

    // MARK: Apply before and after M5

    private func picturePlan(_ names: [String]) -> ArtistPicturePlan {
        let ops = names.map { name -> DeviceFileOperation in
            .write(relativePath: "Artwork/People/\(name).jpg", role: .artistPicture, contents: .data(Data(name.utf8)),
                   subject: String(PodBoxArtName.key(name)))
        }
        return ArtistPicturePlan(operations: ops, alreadyHasPicture: [], noPictureYet: [], overBudget: [],
                                 unnameable: [], foreign: [], uncertain: [], reasons: [:], refusal: nil)
    }

    private func tracks(_ name: String, _ count: Int) -> ArtistOnDevice {
        ArtistOnDevice(name: name, albumFolders: ["Music/\(name)/2000 Album"], trackCount: count)
    }

    func testBeforeM5ApplyWritesOnlyTheFirstPictureTheOwnerChanged() {
        let artists = [tracks("Air", 30), tracks("Beck", 20), tracks("Can", 10)]
        let selection = ArtistPictureSession.applySelection(
            picturePlan(["Air", "Beck", "Can"]), artists: artists, changedNames: ["Can", "Beck"], passedM5: false)
        XCTAssertEqual(selection.operations.map(\.relativePath), ["Artwork/People/Can.jpg"])
        XCTAssertEqual(selection.heldBack, 2, "the rest stay ready")
    }

    func testBeforeM5ApplySkipsAChangedNameWithNothingToWrite() {
        let artists = [tracks("Air", 30), tracks("Beck", 20)]
        let selection = ArtistPictureSession.applySelection(
            picturePlan(["Beck"]), artists: artists, changedNames: ["Air", "Beck"], passedM5: false)
        XCTAssertEqual(selection.operations.map(\.relativePath), ["Artwork/People/Beck.jpg"])
        XCTAssertEqual(selection.heldBack, 0)
    }

    func testBeforeM5ApplyWithNoChangeWritesTheFirstReadyInSheetOrder() {
        let artists = [tracks("Can", 10), tracks("Beck", 20), tracks("Air", 5)]
        let selection = ArtistPictureSession.applySelection(
            picturePlan(["Air", "Can"]), artists: artists, changedNames: [], passedM5: false)
        XCTAssertEqual(selection.operations.map(\.relativePath), ["Artwork/People/Can.jpg"], "most tracks first")
        XCTAssertEqual(selection.heldBack, 1)
    }

    func testAChangedSpellingFindsItsPerson() {
        let artists = [tracks("The Beatles", 30), tracks("Air", 40)]
        let selection = ArtistPictureSession.applySelection(
            picturePlan(["Air", "The Beatles"]), artists: artists, changedNames: ["Beatles, The"], passedM5: false)
        XCTAssertEqual(selection.operations.map(\.relativePath), ["Artwork/People/The Beatles.jpg"])
    }

    func testAfterM5ApplyWritesEveryReadyPicture() {
        let artists = [tracks("Air", 30), tracks("Beck", 20), tracks("Can", 10)]
        let selection = ArtistPictureSession.applySelection(
            picturePlan(["Air", "Beck", "Can"]), artists: artists, changedNames: ["Can"], passedM5: true)
        XCTAssertEqual(selection.operations.count, 3)
        XCTAssertEqual(selection.heldBack, 0)
        let text = ArtistPictureSession.applyConfirmation(count: 3, deviceName: "IPOD")
        XCTAssertEqual(text.title, "Write 3 artist pictures to IPOD?")
        XCTAssertFalse((text.title + text.message + ArtistPictureSession.oneFirstFooter).contains("\u{2014}"))
    }

    func testNothingReadyWritesNothing() {
        let selection = ArtistPictureSession.applySelection(picturePlan([]), artists: [tracks("Air", 1)],
                                                            changedNames: ["Air"], passedM5: false)
        XCTAssertTrue(selection.operations.isEmpty)
        XCTAssertEqual(selection.heldBack, 0)
    }
}
