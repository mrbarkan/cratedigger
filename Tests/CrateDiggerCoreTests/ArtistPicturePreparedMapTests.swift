import XCTest
@testable import CrateDiggerCore

/// The bytes a PodBox iPod gets for each artist come from the artist's
/// default photo (spec §7), prepared exactly as before, and never for an
/// artist the owner kept off the iPod.
final class ArtistPicturePreparedMapTests: XCTestCase {
    private var folder: URL!
    private var store: ArtistProfileStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistPicturePreparedMap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ArtistProfileStore(indexDirectory: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func artist(_ name: String) -> ArtistOnDevice {
        ArtistOnDevice(name: name, albumFolders: ["Music/\(name)/2000 Album"], trackCount: 3)
    }

    @discardableResult
    private func photo(_ name: String, side: Int = 600, red: CGFloat = 0.5) throws -> ArtistPhoto {
        try store.addPhoto(name: name, data: FakePictureFetcher.jpeg(width: side, height: side, red: red),
                           source: .owner, sourceID: nil, credit: nil)
    }

    private func prepared(_ names: [String]) -> [String: Data] {
        ArtistPictureSession.prepared(for: names.map(artist), profiles: store)
    }

    func testPreparedComesFromDefaultPhoto() throws {
        try photo("Air", red: 0.2)
        let chosen = try photo("Air", side: 800, red: 0.9)
        store.setDefault(name: "Air", hash: chosen.hash)

        let map = prepared(["Air", "Can"])
        XCTAssertEqual(Array(map.keys), ["air"], "an artist with no profile gets nothing")
        let original = try XCTUnwrap(store.photoData(hash: chosen.hash))
        XCTAssertEqual(map["air"], ArtistPictureImage.prepare(original),
                       "the owner's default, prepared to the same 400 px JPEG as before")

        // The player takes "Frank Herbert" and "Herbert, Frank" for one person.
        try photo("Herbert, Frank", red: 0.4)
        XCTAssertNotNil(prepared(["Frank Herbert"])["frankherbert"])

        // A default the preparer refuses (under 300 px) sends nothing.
        try photo("Low", side: 200)
        XCTAssertNil(prepared(["Low"])["low"])

        // A default whose file is gone sends nothing.
        let gone = try photo("Yes")
        try FileManager.default.removeItem(at: store.photoURL(hash: gone.hash))
        XCTAssertNil(prepared(["Yes"])["yes"])
    }

    func testNoPhotoAndNotOnIPodAreSkipped() throws {
        try photo("Air")
        try photo("Can")
        try photo("Low")
        store.update(name: "Air") { $0.noPhoto = true }
        store.update(name: "Can") { $0.notOnIPod = true }

        XCTAssertEqual(Array(prepared(["Air", "Can", "Low"]).keys), ["low"])
        XCTAssertNotNil(store.profile(forName: "Can")?.defaultPhotoRef,
                        "not on the iPod hides nothing in the app")
    }
}
