import XCTest
@testable import CrateDiggerCore

/// An `artist.jpg` or `folder.jpg` the owner keeps in their own library, in a
/// folder named for the artist that holds only that artist's albums.
final class LibraryFolderPictureSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderPicture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xd8, 0xff]).write(to: url)
        return url
    }

    private func folder(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: true) }

    func testFindsArtistJpgInNamedSingleArtistFolder() throws {
        try file("Rock/AC-DC/1980 Back in Black/01 Hells Bells.flac")
        try file("Rock/AC-DC/1980 Back in Black/folder.jpg") // the album's own cover: never the portrait
        try file("Rock/AC-DC/folder.jpg")
        let portrait = try file("Rock/AC-DC/Artist.JPG")
        let album = folder("Rock/AC-DC/1980 Back in Black")
        let found = LibraryFolderPictureSource.picture(
            for: "AC/DC", albumFolders: [album],
            artistsByFolder: [folder("Rock/AC-DC"): ["acdc"], folder("Rock"): ["acdc", "beatles"], album: ["acdc"]])
        XCTAssertEqual(found?.standardizedFileURL, portrait.standardizedFileURL, "artist before folder")
    }

    func testFallsBackToFolderJpgAndThroughADiscFolder() throws {
        let cover = try file("Weezer/folder.png")
        try file("Weezer/Weezer/folder.jpg") // the album above the disc folder: its cover, not the portrait
        let disc = folder("Weezer/Weezer/CD1")
        let found = LibraryFolderPictureSource.picture(
            for: "Weezer", albumFolders: [disc],
            artistsByFolder: [folder("Weezer"): ["weezer"], folder("Weezer/Weezer"): ["weezer"], disc: ["weezer"]])
        XCTAssertEqual(found?.standardizedFileURL, cover.standardizedFileURL)
    }

    func testIgnoresFolderHoldingSeveralArtists() throws {
        try file("Prince/folder.jpg")
        let album = folder("Prince/1984 Purple Rain")
        XCTAssertNil(LibraryFolderPictureSource.picture(
            for: "Prince", albumFolders: [album],
            artistsByFolder: [folder("Prince"): ["prince", "princeandtherevolution"]]))
        XCTAssertNil(LibraryFolderPictureSource.picture(for: "Prince", albumFolders: [album], artistsByFolder: [:]),
                     "a folder nobody vouched for is not the artist's alone")
    }

    func testIgnoresFolderWithOtherName() throws {
        try file("Misc/artist.jpg")
        let album = folder("Misc/1980 Back in Black")
        XCTAssertNil(LibraryFolderPictureSource.picture(
            for: "AC/DC", albumFolders: [album], artistsByFolder: [folder("Misc"): ["acdc"]]))
    }

    func testAnAlbumFolderIsNeverTheArtistFolder() throws {
        try file("Weezer/folder.jpg")
        let album = folder("Weezer") // tracks straight in a folder named for the artist
        XCTAssertNil(LibraryFolderPictureSource.picture(
            for: "Weezer", albumFolders: [album], artistsByFolder: [album: ["weezer"]]))
    }
}
