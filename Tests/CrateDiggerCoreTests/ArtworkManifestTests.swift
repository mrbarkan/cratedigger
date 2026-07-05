import XCTest
@testable import CrateDiggerCore

final class ArtworkManifestTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Roles, disc sides and the new per-CD disc numbers all survive a save/load.
    func testSaveLoadRoundTripsRolesSidesAndDiscNumbers() throws {
        var manifest = ArtworkManifest(mediaFormat: .cd)
        manifest.roles = ["cover.jpg": .cover, "cover_alt.jpg": .altCover,
                          "disc1.jpg": .disc, "disc2.jpg": .disc]
        manifest.discNumbers = ["disc1.jpg": 1, "disc2.jpg": 2]
        manifest.discSides = ["disc1.jpg": "A"]

        try manifest.save(to: directory)
        let loaded = try XCTUnwrap(ArtworkManifest.load(from: directory))

        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.roles["cover_alt.jpg"], .altCover)
        XCTAssertEqual(loaded.discNumbers?["disc2.jpg"], 2)
    }

    /// Manifests written before `discNumbers` existed must still decode (as nil),
    /// so upgrading never drops a user's existing role assignments.
    func testDecodesLegacyManifestWithoutDiscNumbers() throws {
        let legacyJSON = """
        { "roles": { "cover.jpg": "Cover", "disc.jpg": "Disc" },
          "discSides": { "disc.jpg": "A" } }
        """
        let manifest = try JSONDecoder().decode(ArtworkManifest.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(manifest.discNumbers)
        XCTAssertEqual(manifest.roles["cover.jpg"], .cover)
        XCTAssertEqual(manifest.roles["disc.jpg"], .disc)
        XCTAssertEqual(manifest.discSides?["disc.jpg"], "A")
    }
}
