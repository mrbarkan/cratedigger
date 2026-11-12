import XCTest
@testable import CrateDiggerCore

final class PodBoxArtLookupTests: XCTestCase {
    private func tree(people: [String] = [], covers: [String] = [],
                      images: [String: [String]] = [:], audio: Set<String> = [],
                      artists: [String: Set<String>] = [:], musicFolder: String? = "Music") -> DeviceArtTree {
        DeviceArtTree(peopleFiles: people, coverFiles: covers, folderImages: images,
                      foldersWithAudio: audio, artistsByFolder: artists, musicFolder: musicFolder)
    }

    func testPeopleFileWins() {
        let tree = tree(people: ["Björk.jpg"],
                        images: ["Music/Björk": ["folder.jpg"]],
                        artists: ["Music/Björk": ["bjork"]])
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Bjork", albumFolders: ["Music/Björk/Post"], tree: tree),
                       "Artwork/People/Björk.jpg")
    }

    func testPeopleFileMatchesByAltKey() {
        let tree = tree(people: ["Herbert, Frank.jpg"])
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Frank Herbert", albumFolders: [], tree: tree),
                       "Artwork/People/Herbert, Frank.jpg")
    }

    func testPeopleFileWithWrongExtensionIgnored() {
        let tree = tree(people: ["Frank Herbert.txt", "Frank Herbert"])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "Frank Herbert", albumFolders: [], tree: tree))
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "Frank Herbert", albumFolders: [],
                                                     tree: self.tree(people: ["Frank Herbert.WEBP"])),
                       "Artwork/People/Frank Herbert.WEBP")
    }

    func testArtistFolderImageFoundThroughCategoryLevel() {
        let tree = tree(images: ["Music/Rock/AC-DC": ["folder.jpg"]],
                        audio: ["Music/Rock/AC-DC/1980 Back in Black"],
                        artists: ["Music/Rock/AC-DC": ["acdc"], "Music/Rock": ["acdc", "beatles"],
                                  "Music": ["acdc", "beatles"]])
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/Rock/AC-DC/1980 Back in Black"],
                                                     tree: tree),
                       "Music/Rock/AC-DC/folder.jpg")
    }

    func testCoverPreferredOverFolder() {
        let tree = tree(images: ["Music/AC-DC": ["folder.jpg", "cover.png", "cover.jpg"]],
                        audio: ["Music/AC-DC/Powerage"], artists: ["Music/AC-DC": ["acdc"]])
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/AC-DC/Powerage"], tree: tree),
                       "Music/AC-DC/cover.jpg")
    }

    func testCategoryFolderWithManyArtistsIgnored() {
        let tree = tree(images: ["Music/Rock": ["folder.jpg"]],
                        audio: ["Music/Rock/AC-DC/Powerage", "Music/Rock/Beatles/Help"],
                        artists: ["Music/Rock": ["acdc", "beatles"], "Music/Rock/AC-DC": ["acdc"]])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/Rock/AC-DC/Powerage"], tree: tree))
    }

    /// Review Focus 2: the album cover of a self-titled album is not a portrait.
    func testAlbumCoverInSelfTitledFolderDoesNotBlock() {
        let tree = tree(images: ["Music/Weezer/Weezer": ["cover.jpg"]],
                        audio: ["Music/Weezer/Weezer"],
                        artists: ["Music/Weezer/Weezer": ["weezer"], "Music/Weezer": ["weezer"],
                                  "Music": ["weezer"]])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "Weezer", albumFolders: ["Music/Weezer/Weezer"], tree: tree))
    }

    func testNamedFolderMoreThanThreeLevelsUpIgnored() {
        let album = "Music/AC-DC/a/b/c/Powerage"
        let tree = tree(images: ["Music/AC-DC": ["folder.jpg"]], audio: [album],
                        artists: ["Music/AC-DC": ["acdc"], "Music/AC-DC/a/b/c": ["acdc"], "Music/AC-DC/a/b": ["acdc"]])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: [album], tree: tree))
        // Three levels up is still in reach.
        let near = "Music/AC-DC/a/b/Powerage"
        let reachable = self.tree(images: ["Music/AC-DC": ["folder.jpg"]], audio: [near],
                                  artists: ["Music/AC-DC": ["acdc"]])
        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: [near], tree: reachable),
                       "Music/AC-DC/folder.jpg")
    }

    func testNeverLooksAboveTheMusicFolder() {
        // The volume root is the album's grandparent, and the AC-DC folder above
        // the music folder is named after the artist: neither is looked at.
        let tree = tree(images: ["": ["folder.jpg"], "AC-DC": ["cover.jpg"]],
                        audio: ["AC-DC/Music/Powerage"],
                        artists: ["": ["acdc"], "AC-DC": ["acdc"]], musicFolder: "AC-DC/Music")
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["AC-DC/Music/Powerage"], tree: tree))
        let rootTree = self.tree(images: ["": ["folder.jpg"]], audio: ["Music/Powerage"], artists: ["": ["acdc"]])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/Powerage"], tree: rootTree))
    }

    func testNoPictureGivesNil() {
        let tree = tree(people: ["Someone Else.jpg"],
                        images: ["Music/AC-DC/Powerage": ["cover.jpg"]],
                        audio: ["Music/AC-DC/Powerage"], artists: ["Music/AC-DC": ["acdc"]])
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/AC-DC/Powerage"], tree: tree))
    }

    func testScanBuildsTreeFromFakeIPod() throws {
        let iPod = try FakeIPod()
        let before = try iPod.manifest()
        let acdc = try iPod.addAlbum(category: "Rock", artist: "AC-DC", folder: "1980 Back in Black",
                                     tracks: ["01 Hells Bells.m4a"], appleDoubleTwins: true)
        let beatles = try iPod.addAlbum(category: "Rock", artist: "Beatles", folder: "1965 Help",
                                        tracks: ["01 Help.m4a"], cover: false)
        try iPod.addFile("Music/Rock/AC-DC/folder.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/People/Björk.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/People/.hidden.jpg", Data([0xff, 0xd8]))
        try iPod.addFile("Artwork/Covers/Beatles - Help.jpg", Data([0xff, 0xd8]))

        func track(_ folder: URL, _ file: String, albumArtist: String?, artist: String) -> LoadedTrack {
            LoadedTrack(track: AudioTrack(fileURL: folder.appendingPathComponent(file), title: file, artist: artist),
                        metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist))
        }
        let catalog = [
            track(acdc, "01 Hells Bells.m4a", albumArtist: nil, artist: "AC/DC"),
            track(beatles, "01 Help.m4a", albumArtist: "The Beatles", artist: "Beatles"),
        ]

        let tree = DeviceArtTree.scan(volumeRoot: iPod.root, musicSubpath: "Music", catalog: catalog)
        XCTAssertEqual(tree.peopleFiles, ["Björk.jpg"])
        XCTAssertEqual(tree.coverFiles, ["Beatles - Help.jpg"])
        XCTAssertEqual(tree.folderImages["Music/Rock/AC-DC"], ["folder.jpg"])
        XCTAssertEqual(tree.folderImages["Music/Rock/AC-DC/1980 Back in Black"], ["cover.jpg"])
        XCTAssertEqual(tree.foldersWithAudio, ["Music/Rock/AC-DC/1980 Back in Black", "Music/Rock/Beatles/1965 Help"])
        XCTAssertEqual(tree.artistsByFolder["Music/Rock/AC-DC/1980 Back in Black"], ["acdc"])
        XCTAssertEqual(tree.artistsByFolder["Music/Rock/AC-DC"], ["acdc"])
        XCTAssertEqual(tree.artistsByFolder["Music/Rock"], ["acdc", "beatles"])
        XCTAssertEqual(tree.artistsByFolder["Music"], ["acdc", "beatles"])
        XCTAssertNil(tree.artistsByFolder[""], "nothing above the music folder")
        XCTAssertEqual(tree.musicFolder, "Music")

        XCTAssertEqual(PodBoxArtLookup.artistPicture(for: "AC/DC", albumFolders: ["Music/Rock/AC-DC/1980 Back in Black"],
                                                     tree: tree),
                       "Music/Rock/AC-DC/folder.jpg")
        XCTAssertNil(PodBoxArtLookup.artistPicture(for: "The Beatles", albumFolders: ["Music/Rock/Beatles/1965 Help"],
                                                   tree: tree))
        iPod.assertPlayerStateUntouched(since: before)
    }

    func testPersonSkipsVariousAndUnknown() {
        func person(albumArtist: String?, artist: String) -> String? {
            DeviceArtTree.person(for: LoadedTrack(
                track: AudioTrack(fileURL: URL(fileURLWithPath: "/x.m4a"), title: "x", artist: artist),
                metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist)))
        }
        XCTAssertNil(person(albumArtist: "Various Artists", artist: "Beck"))
        XCTAssertNil(person(albumArtist: "  VARIOUS ARTISTS ", artist: "Beck"))
        XCTAssertNil(person(albumArtist: nil, artist: "Unknown Artist"))
        XCTAssertNil(person(albumArtist: nil, artist: "<untagged>"))
        XCTAssertNil(person(albumArtist: nil, artist: "<UNTAGGED>"))
        XCTAssertNil(person(albumArtist: nil, artist: "   "))
        XCTAssertEqual(person(albumArtist: "Air", artist: "Beck"), "Air")
    }

    func testPersonFallsBackToArtist() {
        func person(albumArtist: String?, artist: String) -> String? {
            DeviceArtTree.person(for: LoadedTrack(
                track: AudioTrack(fileURL: URL(fileURLWithPath: "/x.m4a"), title: "x", artist: artist),
                metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist)))
        }
        XCTAssertEqual(person(albumArtist: nil, artist: "Beck"), "Beck")
        XCTAssertEqual(person(albumArtist: "  ", artist: "Beck"), "Beck")
    }
}
