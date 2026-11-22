import XCTest
@testable import CrateDiggerCore

/// The player's people step (PodBox art cache): People file, else the highest
/// folder named for the person, else the folder above a track's or the one
/// above that unless it is a library folder or the volume root.
final class PodBoxArtLookupTests: XCTestCase {
    private func tree(people: [String] = [], covers: [String] = [],
                      images: [String: [String]] = [:], audio: Set<String> = [],
                      artists: [String: Set<String>] = [:], library: Set<String>? = [],
                      full: Bool = false) -> DeviceArtTree {
        DeviceArtTree(peopleFiles: people, coverFiles: covers, folderImages: images,
                      foldersWithAudio: audio, artistsByFolder: artists, libraryFolders: library,
                      libraryTableFull: full)
    }

    private func lookup(_ name: String, _ folders: [String], _ tree: DeviceArtTree) -> PodBoxArtLookup.Outcome {
        PodBoxArtLookup.artistPicture(for: name, albumFolders: folders, tree: tree)
    }

    private func assertUncertain(_ outcome: PodBoxArtLookup.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .uncertain = outcome else {
            return XCTFail("expected uncertain, got \(outcome)", file: file, line: line)
        }
    }

    // MARK: Step 1: /Artwork/People

    func testPeopleFileWins() {
        let tree = tree(people: ["Björk.jpg"], images: ["Music/Björk": ["folder.jpg"]])
        XCTAssertEqual(lookup("Bjork", ["Music/Björk/Post"], tree), .found("Artwork/People/Björk.jpg"))
    }

    func testPeopleFileMatchesByAltKey() {
        XCTAssertEqual(lookup("Frank Herbert", [], tree(people: ["Herbert, Frank.jpg"])),
                       .found("Artwork/People/Herbert, Frank.jpg"))
    }

    /// The player's `aa_central_load` skips names without a picture
    /// extension; a matching one is uncertain only out of caution. It also
    /// skips dot-names, and so does the lookup (review M4): a `._` twin is
    /// not a picture and does not count.
    func testPeopleFileWithWrongExtensionIsUncertain() {
        assertUncertain(lookup("Frank Herbert", [], tree(people: ["Frank Herbert.txt"])))
        XCTAssertEqual(lookup("Frank Herbert", [], tree(people: ["Frank Herbert.jpg", "._Frank Herbert.jpg"])),
                       .found("Artwork/People/Frank Herbert.jpg"))
        XCTAssertEqual(lookup("Prince", [], tree(people: ["._Prince.jpg", ".Prince.jpg"])), .none)
        XCTAssertEqual(lookup("Frank Herbert", [], tree(people: ["Frank Herbert.WEBP"])),
                       .found("Artwork/People/Frank Herbert.WEBP"))
        XCTAssertEqual(lookup("Frank Herbert", [], tree(people: ["Frank Zappa.txt"])), .none)
    }

    // MARK: Step 2: the highest named folder

    func testArtistFolderImageFoundThroughCategoryLevel() {
        let tree = tree(images: ["Music/Rock/AC-DC": ["folder.jpg"]], library: ["Music/Rock"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Rock/AC-DC/1980 Back in Black"], tree),
                       .found("Music/Rock/AC-DC/folder.jpg"))
    }

    func testImageOrderUnderscoreThenCoverThenFolder() {
        let tree = tree(images: ["Music/AC-DC": ["folder.jpg", "cover.png", "Cover.JPG", "_.gif"]])
        XCTAssertEqual(lookup("AC/DC", ["Music/AC-DC/Powerage"], tree), .found("Music/AC-DC/_.gif"))
        let noUnderscore = self.tree(images: ["Music/AC-DC": ["folder.jpg", "cover.png", "Cover.JPG"]])
        XCTAssertEqual(lookup("AC/DC", ["Music/AC-DC/Powerage"], noUnderscore), .found("Music/AC-DC/Cover.JPG"))
    }

    /// Review I1: loose singles directly in the artist folder do not stop the
    /// player using its folder.jpg.
    func testPrinceFolderHoldingLooseTracksStillGivesItsPicture() {
        let tree = tree(images: ["Music/Prince": ["folder.jpg"], "Music/Prince/1984 Purple Rain": ["cover.jpg"]],
                        audio: ["Music/Prince", "Music/Prince/1984 Purple Rain"], library: ["Music"])
        XCTAssertEqual(lookup("Prince", ["Music/Prince", "Music/Prince/1984 Purple Rain"], tree),
                       .found("Music/Prince/folder.jpg"))
        XCTAssertEqual(lookup("Prince", ["Music/Prince"], tree), .found("Music/Prince/folder.jpg"))
    }

    /// Review Focus 2: the highest named folder is `Music/Weezer`, so the
    /// self-titled album's cover is not the portrait.
    func testAlbumCoverInSelfTitledFolderDoesNotBlock() {
        let tree = tree(images: ["Music/Weezer/Weezer": ["cover.jpg"]],
                        audio: ["Music/Weezer/Weezer"], library: ["Music"])
        XCTAssertEqual(lookup("Weezer", ["Music/Weezer/Weezer"], tree), .none)
        let withPortrait = self.tree(images: ["Music/Weezer/Weezer": ["cover.jpg"], "Music/Weezer": ["folder.jpg"]],
                                     audio: ["Music/Weezer/Weezer"], library: ["Music"])
        XCTAssertEqual(lookup("Weezer", ["Music/Weezer/Weezer"], withPortrait), .found("Music/Weezer/folder.jpg"))
    }

    /// Where the album folder is the only folder named for the artist, the
    /// player does use its cover. Reported as it is.
    func testFlatSelfTitledFolderGivesItsCover() {
        let tree = tree(images: ["Music/Weezer": ["cover.jpg"]], audio: ["Music/Weezer"], library: ["Music"])
        XCTAssertEqual(lookup("Weezer", ["Music/Weezer"], tree), .found("Music/Weezer/cover.jpg"))
    }

    func testDiscFolderTakesTheImageAboveIt() {
        // The fallback's second folder is a disc folder: the player takes the
        // album folder's cover above it, three above the track.
        let tree = tree(images: ["Music/Box": ["cover.jpg"]], library: ["Music"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Box/CD1/Side A/Tracks"], tree), .found("Music/Box/cover.jpg"))
        XCTAssertEqual(lookup("AC/DC", ["Music/Box/Extras/Side A/Tracks"], tree), .none, "not a disc folder")
        XCTAssertTrue(PodBoxArtLookup.isDiscFolder("CD1"))
        XCTAssertTrue(PodBoxArtLookup.isDiscFolder("Disc 2"))
        XCTAssertTrue(PodBoxArtLookup.isDiscFolder("disk_3"))
        XCTAssertTrue(PodBoxArtLookup.isDiscFolder("disc-04"))
        XCTAssertFalse(PodBoxArtLookup.isDiscFolder("Disc 1 of 2"))
        XCTAssertFalse(PodBoxArtLookup.isDiscFolder("Disco"))
        XCTAssertFalse(PodBoxArtLookup.isDiscFolder("CD"))
        XCTAssertFalse(PodBoxArtLookup.isDiscFolder("CD-"))
    }

    /// The player ignores a named folder four levels up, but a named folder
    /// with a picture that no track reaches is held as uncertain (review I2):
    /// the catalog may be missing the tracks that lead there.
    func testNamedFolderMoreThanThreeLevelsUpIgnored() {
        let tree = tree(images: ["Music/AC-DC": ["folder.jpg"]], library: ["Music"])
        assertUncertain(lookup("AC/DC", ["Music/AC-DC/a/b/c/Powerage"], tree))
        XCTAssertEqual(lookup("AC/DC", ["Music/AC-DC/a/b/c/Powerage"], self.tree(library: ["Music"])), .none)
        XCTAssertEqual(lookup("AC/DC", ["Music/AC-DC/a/b/Powerage"], tree), .found("Music/AC-DC/folder.jpg"))
    }

    func testHighestNamedFolderWinsEvenWithoutAnImage() {
        // Music/Prince is the highest; it has no image, so the named folder
        // below it does not count and the fallback looks above each track.
        let tree = tree(images: ["Music/Prince/Prince": ["folder.jpg"]], library: ["Music"])
        XCTAssertEqual(lookup("Prince", ["Music/Prince/Prince/1999"], tree), .found("Music/Prince/Prince/folder.jpg"),
                       "the fallback's first step is the track folder's parent")
        // A track folder named for him under a higher named folder: its own
        // image is neither the named folder's nor above the track.
        XCTAssertEqual(lookup("Prince", ["Music/Prince/Prince"], tree), .none)
    }

    func testNamedFoldersTyingAtOneHeightAreUncertain() {
        let tree = tree(images: ["Music/Rock/Prince": ["folder.jpg"]], library: ["Music", "Music/Rock", "Music/Funk"])
        assertUncertain(lookup("Prince", ["Music/Rock/Prince/1999", "Music/Funk/Prince/Lovesexy"], tree))
        // Neither has an image: no tie to break.
        XCTAssertEqual(lookup("Prince", ["Music/Rock/Prince/1999", "Music/Funk/Prince/Lovesexy"],
                              self.tree(library: ["Music", "Music/Rock", "Music/Funk"])), .none)
    }

    // MARK: Step 3: the folders above

    func testCategoryFolderWithManyArtistsIgnored() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"]], library: ["Music", "Music/Rock"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Rock/AC-DC/Powerage"], tree), .none)
    }

    /// The real rule: a folder holding many artists' albums but only one
    /// named folder is not a library folder.
    func testFolderAboveWithOneNamedFolderIsUsed() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"]], library: ["Music"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Rock/Live Albums/Powerage"], tree), .found("Music/Rock/folder.jpg"))
    }

    func testLibraryFoldersDerivedWithoutTheCatalog() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"]],
                        artists: ["Music/Rock/AC-DC": ["acdc"], "Music/Rock/Beatles": ["beatles"],
                                  "Music/Rock": ["acdc", "beatles"]], library: nil)
        XCTAssertEqual(tree.libraryFolders, ["Music/Rock"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Rock/AC-DC/Powerage"], tree), .none)
    }

    func testDifferentImagesAboveDifferentTracksAreUncertain() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"], "Music/Pop": ["folder.jpg"]], library: ["Music"])
        assertUncertain(lookup("Beck", ["Music/Rock/Odelay", "Music/Pop/Guero"], tree))
    }

    func testFullLibraryTableIsUncertain() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"]], library: ["Music"], full: true)
        assertUncertain(lookup("AC/DC", ["Music/Rock/Live/Powerage"], tree))
        XCTAssertEqual(lookup("AC/DC", ["Music/Rock/Live/Powerage"], self.tree(library: ["Music"], full: true)), .none)
    }

    func testNeverLooksAtTheVolumeRoot() {
        let tree = tree(images: ["": ["folder.jpg", "cover.jpg"]], library: [])
        XCTAssertEqual(lookup("AC/DC", ["Music/Powerage"], tree), .none, "the grandparent is the root")
        XCTAssertEqual(lookup("AC/DC", ["AC-DC"], self.tree(images: ["": ["folder.jpg"]])), .none)
    }

    func testNoPictureGivesNil() {
        let tree = tree(people: ["Someone Else.jpg"], images: ["Music/Powerage": ["cover.jpg"]],
                        audio: ["Music/Powerage"], library: ["Music"])
        XCTAssertEqual(lookup("AC/DC", ["Music/Powerage"], tree), .none)
        XCTAssertNil(lookup("AC/DC", ["Music/Powerage"], tree).foundPath)
        XCTAssertEqual(lookup("!!!", ["Music/!!!"], self.tree(images: ["Music/!!!": ["cover.jpg"]])), .none,
                       "a name the player cannot key gets nothing")
    }

    // MARK: Scan

    func testScanBuildsTreeFromFakeIPod() throws {
        let iPod = try FakeIPod()
        let before = try iPod.manifest()
        let acdc = try iPod.addAlbum(category: "Rock", artist: "AC-DC", folder: "1980 Back in Black",
                                     tracks: ["01 Hells Bells.m4a"], appleDoubleTwins: true)
        let beatles = try iPod.addAlbum(category: "Rock", artist: "Beatles", folder: "1965 Help",
                                        tracks: ["01 Help.m4a"], cover: false)
        let prince = try iPod.addAlbum(category: nil, artist: "Prince", folder: "1999",
                                       tracks: ["01 1999.m4a"], cover: false)
        try iPod.addFile("Music/Prince/Loose Single.m4a", Data([0, 0, 0, 0x20]))
        try iPod.addFile("Music/Prince/folder.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Music/Rock/AC-DC/folder.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/People/Björk.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/People/.hidden.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/People/Sigur Ro\u{301}s.jpg", Data([0xff, 0xd8])) // decomposed, as macOS may hand it back
        try iPod.addFile("Artwork/Covers/Beatles - Help.jpg", Data([0xff, 0xd8]))

        func track(_ folder: URL, _ file: String, albumArtist: String?, artist: String) -> LoadedTrack {
            LoadedTrack(track: AudioTrack(fileURL: folder.appendingPathComponent(file), title: file, artist: artist),
                        metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist))
        }
        let catalog = [
            track(acdc, "01 Hells Bells.m4a", albumArtist: nil, artist: "AC/DC"),
            track(beatles, "01 Help.m4a", albumArtist: "The Beatles", artist: "Beatles"),
            track(prince, "01 1999.m4a", albumArtist: nil, artist: "Prince"),
            track(prince.deletingLastPathComponent(), "Loose Single.m4a", albumArtist: nil, artist: "Prince"),
        ]

        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music", catalog: catalog)
        XCTAssertEqual(tree.peopleFiles, [".hidden.jpg", "Björk.jpg", "Sigur R\u{F3}s.jpg"], "all of readdir, NFC")
        XCTAssertEqual(tree.peopleFiles.last?.unicodeScalars.count, 13)
        XCTAssertEqual(tree.coverFiles, ["Beatles - Help.jpg"])
        XCTAssertEqual(tree.folderImages["Music/Rock/AC-DC"], ["folder.jpg"])
        XCTAssertEqual(tree.folderImages["Music/Rock/AC-DC/1980 Back in Black"], ["cover.jpg"])
        XCTAssertEqual(tree.foldersWithAudio, ["Music/Rock/AC-DC/1980 Back in Black", "Music/Rock/Beatles/1965 Help",
                                               "Music/Prince/1999", "Music/Prince"])
        XCTAssertEqual(tree.artistsByFolder["Music/Rock/AC-DC"], ["acdc"])
        XCTAssertEqual(tree.artistsByFolder["Music/Rock"], ["acdc", "beatles"])
        XCTAssertEqual(tree.artistsByFolder["Music"], ["acdc", "beatles", "prince"])
        XCTAssertNil(tree.artistsByFolder[""], "nothing above the music folder")
        // Music/Rock holds AC-DC and Beatles, named for two people; Music holds Prince.
        XCTAssertEqual(tree.libraryFolders, ["Music/Rock"])
        XCTAssertFalse(tree.libraryTableFull)

        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: [acdc.path.replacingOccurrences(
            of: iPod.root.path + "/", with: "")], tree: tree), .found("Music/Rock/AC-DC/folder.jpg"))
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Prince", albumFolders: ["Music/Prince", "Music/Prince/1999"],
                                                     tree: tree), .found("Music/Prince/folder.jpg"))
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "The Beatles", albumFolders: ["Music/Rock/Beatles/1965 Help"],
                                                     tree: tree), .none)
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Sigur Rós", albumFolders: [], tree: tree),
                       .found("Artwork/People/Sigur R\u{F3}s.jpg"))
        iPod.assertPlayerStateUntouched(since: before)
        XCTAssertEqual(tree.musicFolder, "Music")
        XCTAssertTrue(tree.listedFolders?.isSuperset(of: ["Music", "Music/Prince", "Music/Rock/AC-DC", ""]) == true)
    }

    private func scanTrack(_ iPod: FakeIPod, _ relative: String, artist: String) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: iPod.root.appendingPathComponent(relative), title: "t", artist: artist),
                    metadata: ConversionMetadata(artist: artist))
    }

    private func setHidden(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, true, "the flag did not stick")
    }

    /// Re-review item 1: on FAT the hidden attribute is the hidden flag, and
    /// Windows Media Player writes `Folder.jpg` hidden. The player ignores the
    /// attribute, so the scan must too, for files and for folders.
    func testHiddenFlagFileAndFolderAreStillSeen() throws {
        let iPod = try FakeIPod()
        try iPod.addFile("Music/Prince/a.mp3", Data([0, 0, 0, 0x20]))
        try setHidden(try iPod.addFile("Music/Prince/Folder.jpg", Data([0xff, 0xd8])))
        try iPod.addFile("Music/Weezer/Blue/01.mp3", Data([0, 0, 0, 0x20]))
        try iPod.addFile("Music/Weezer/folder.jpg", Data([0xff, 0xd8]))
        try setHidden(iPod.root.appendingPathComponent("Music/Weezer"))
        let catalog = [scanTrack(iPod, "Music/Prince/a.mp3", artist: "Prince"),
                       scanTrack(iPod, "Music/Weezer/Blue/01.mp3", artist: "Weezer")]

        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music", catalog: catalog)

        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Prince", albumFolders: ["Music/Prince"], tree: tree),
                       .found("Music/Prince/Folder.jpg"))
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Weezer", albumFolders: ["Music/Weezer/Blue"], tree: tree),
                       .found("Music/Weezer/folder.jpg"))
    }

    /// Review I2: a folder named for the person, with a picture, that none
    /// of the catalog's tracks reaches (a stale catalog) is uncertain.
    func testNamedFolderWithAPictureOffTheCatalogIsUncertain() {
        let tree = tree(images: ["Music/Air": ["folder.jpg"], "Music/Electronic/Air Remixed": ["Cover.png"]])
        assertUncertain(lookup("Air", ["Music/Electronic/Moon Safari"], tree))
        // On the chain it is simply found.
        XCTAssertEqual(lookup("Air", ["Music/Air/Moon Safari"], self.tree(images: ["Music/Air": ["folder.jpg"]])),
                       .found("Music/Air/folder.jpg"))
        // A named folder with only other images is not a picture.
        XCTAssertEqual(lookup("Air", ["Music/Electronic/Moon Safari"],
                              self.tree(images: ["Music/Air": ["back.jpg"]])), .none)
    }

    /// Review M3: a People folder that cannot be read is not an empty one.
    func testUnreadablePeopleFolderIsUncertain() throws {
        let iPod = try FakeIPod()
        try iPod.addFile("Music/Air/Moon Safari/01.mp3", Data([0, 0, 0, 0x20]))
        try iPod.addFile("Artwork/People/Someone.jpg", Data([0xff, 0xd8]))
        let people = iPod.root.appendingPathComponent("Artwork/People").path
        XCTAssertEqual(chmod(people, 0o000), 0)
        defer { chmod(people, 0o755) }
        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music",
                                      catalog: [scanTrack(iPod, "Music/Air/Moon Safari/01.mp3", artist: "Air")])
        XCTAssertFalse(tree.artworkListed)
        assertUncertain(PodBoxArtLookup.artistPicture(for: "Air", albumFolders: ["Music/Air/Moon Safari"], tree: tree))

        // A missing /Artwork reads as empty.
        let bare = try FakeIPod()
        try bare.addFile("Music/Air/Moon Safari/01.mp3", Data([0, 0, 0, 0x20]))
        let bareTree = DeviceArtTree.scan(volumeRoot: bare.root, musicSubpath: "Music",
                                          catalog: [scanTrack(bare, "Music/Air/Moon Safari/01.mp3", artist: "Air")])
        XCTAssertTrue(bareTree.artworkListed)
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Air", albumFolders: ["Music/Air/Moon Safari"], tree: bareTree),
                       .none)
    }

    /// Re-review item 2: "listed, no image" and "never listed" differ.
    func testUnlistedFolderIsUncertain() throws {
        let partial = tree(listed: ["Music", "Music/Air/Moon Safari"])
        assertUncertain(lookup("Air", ["Music/Air/Moon Safari"], partial))
        let whole = tree(listed: ["Music", "Music/Air", "Music/Air/Moon Safari"])
        XCTAssertEqual(lookup("Air", ["Music/Air/Moon Safari"], whole), .none)

        // From a real scan: a catalog track whose folder is not on the device.
        let iPod = try FakeIPod()
        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music",
                                      catalog: [scanTrack(iPod, "Music/Air/Talkie Walkie/01.mp3", artist: "Air")])
        assertUncertain(PodBoxArtLookup.artistPicture(for: "Air", albumFolders: ["Music/Air/Talkie Walkie"], tree: tree))
    }

    private func tree(listed: Set<String>) -> DeviceArtTree {
        DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:], foldersWithAudio: [],
                      artistsByFolder: [:], libraryFolders: [], listedFolders: listed)
    }

    /// Re-review item 3: the player also gives an ebook author the picture
    /// of a folder named for them. Books are not modelled: uncertain.
    func testBookFolderNamedForThePersonIsUncertain() throws {
        let iPod = try FakeIPod()
        try iPod.addFile("Music/Leonard Cohen/Songs/01.mp3", Data([0, 0, 0, 0x20]))
        try iPod.addFile("Books/Leonard Cohen/cover.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Music/Patti Smith/Horses/01.mp3", Data([0, 0, 0, 0x20]))
        try iPod.addFile("Music/Patti Smith/Just Kids.epub", Data("PK".utf8))
        try iPod.addFile("Music/Air/Moon Safari/01.mp3", Data([0, 0, 0, 0x20]))
        let catalog = [scanTrack(iPod, "Music/Leonard Cohen/Songs/01.mp3", artist: "Leonard Cohen"),
                       scanTrack(iPod, "Music/Patti Smith/Horses/01.mp3", artist: "Patti Smith"),
                       scanTrack(iPod, "Music/Air/Moon Safari/01.mp3", artist: "Air")]

        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music", catalog: catalog)

        XCTAssertTrue(tree.bookFolders.isSuperset(of: ["Books", "Books/Leonard Cohen", "Music/Patti Smith"]))
        assertUncertain(PodBoxArtLookup.artistPicture(for: "Leonard Cohen", albumFolders: ["Music/Leonard Cohen/Songs"],
                                                      tree: tree))
        assertUncertain(PodBoxArtLookup.artistPicture(for: "Patti Smith", albumFolders: ["Music/Patti Smith/Horses"],
                                                      tree: tree))
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Air", albumFolders: ["Music/Air/Moon Safari"], tree: tree),
                       .none)
    }

    // MARK: Person

    private func person(albumArtist: String?, artist: String) -> String? {
        DeviceArtTree.person(for: LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/x.m4a"), title: "x", artist: artist),
            metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist)))
    }

    func testPersonSkipsVariousAndUnknown() {
        XCTAssertNil(person(albumArtist: "Various Artists", artist: "Beck"))
        XCTAssertNil(person(albumArtist: "  VARIOUS ARTISTS ", artist: "Beck"))
        XCTAssertNil(person(albumArtist: nil, artist: "Unknown Artist"))
        XCTAssertNil(person(albumArtist: nil, artist: "<untagged>"))
        XCTAssertNil(person(albumArtist: nil, artist: "<UNTAGGED>"))
        XCTAssertNil(person(albumArtist: nil, artist: "   "))
        XCTAssertEqual(person(albumArtist: "Air", artist: "Beck"), "Air")
    }

    func testPersonFallsBackToArtist() {
        XCTAssertEqual(person(albumArtist: nil, artist: "Beck"), "Beck")
        XCTAssertEqual(person(albumArtist: "  ", artist: "Beck"), "Beck")
    }
}
