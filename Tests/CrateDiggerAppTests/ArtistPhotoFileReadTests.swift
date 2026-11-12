#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Reading a picture file the owner chose for an artist: a symbolic link is
/// followed to its picture, and nothing over the limit is ever read whole.
final class ArtistPhotoFileReadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPhotoFileRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAPlainFileAndALinkToOneReadTheSame() throws {
        let picture = folder.appendingPathComponent("portrait.jpg")
        try Data("picture bytes".utf8).write(to: picture)
        let link = folder.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: picture)

        XCTAssertEqual(try LibraryViewModel.readArtistPhotoFile(picture), Data("picture bytes".utf8))
        XCTAssertEqual(try LibraryViewModel.readArtistPhotoFile(link), Data("picture bytes".utf8))
    }

    func testAFolderIsNotAPicture() {
        XCTAssertThrowsError(try LibraryViewModel.readArtistPhotoFile(folder)) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .unreadablePhoto)
        }
    }

    func testAFileOverTheLimitIsRefused() throws {
        let big = folder.appendingPathComponent("huge.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ArtistPictureImage.maximumSourceBytes + 1))   // sparse: costs nothing
        try handle.close()
        XCTAssertThrowsError(try LibraryViewModel.readArtistPhotoFile(big)) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .photoTooLarge)
        }
    }
}
#endif
