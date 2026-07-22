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

    func testRolesSortCoverFirstThenBackDiscBooklet() {
        let shuffled: [ArtworkRole] = [.ignore, .bookletPage, .back, .auto, .cover, .disc, .inlay, .altCover]
        let sorted = shuffled.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sorted, [.cover, .altCover, .back, .disc, .inlay, .bookletPage, .auto, .ignore])
    }

    func testEveryRoleHasADistinctSortOrder() {
        let orders = ArtworkRole.allCases.map(\.sortOrder)
        XCTAssertEqual(Set(orders).count, ArtworkRole.allCases.count,
                       "Duplicate sortOrder makes grid ordering non-deterministic")
    }
}

final class ArtworkRoleTaxonomyTests: XCTestCase {
    /// The extended package roles round-trip through the manifest JSON.
    func testExtendedRolesRoundTrip() throws {
        let manifest = ArtworkManifest(roles: [
            "matrix.jpg": .matrixRunout,
            "sticker.jpg": .sticker,
            "spine.jpg": .spine,
            "sleeve.jpg": .sleeve,
            "obi.jpg": .obi,
            "poster.jpg": .poster,
            "wrapped.jpg": .wrapped
        ])
        let data = try JSONEncoder().encode(manifest)
        let loaded = try JSONDecoder().decode(ArtworkManifest.self, from: data)
        XCTAssertEqual(loaded.roles["matrix.jpg"], .matrixRunout)
        XCTAssertEqual(loaded.roles["wrapped.jpg"], .wrapped)
        XCTAssertEqual(loaded.roles["obi.jpg"], .obi)
    }

    /// A manifest from a future app version with a role this build doesn't
    /// know must not lose the whole manifest — the stranger decays to .auto.
    func testUnknownRoleDecodesAsAutoNotFailure() throws {
        let json = """
        { "roles": { "cover.jpg": "Cover", "holo.jpg": "Hologram Foil" } }
        """
        let manifest = try JSONDecoder().decode(ArtworkManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.roles["cover.jpg"], .cover)
        XCTAssertEqual(manifest.roles["holo.jpg"], .auto)
    }

    func testAssignableExcludesBookkeepingRoles() {
        XCTAssertFalse(ArtworkRole.assignable.contains(.auto))
        XCTAssertFalse(ArtworkRole.assignable.contains(.ignore))
        XCTAssertEqual(ArtworkRole.assignable.first, .cover)
        XCTAssertEqual(ArtworkRole.assignable.count, ArtworkRole.allCases.count - 2)
    }

    func testCAATypesMapToPreciseRoles() {
        XCTAssertEqual(ArtworkRole.forCAATypes(["Front"]), .cover)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Back", "Spine"]), .back)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Spine"]), .spine)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Medium"]), .disc)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Matrix/Runout"]), .matrixRunout)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Sticker"]), .sticker)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Obi"]), .obi)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Sleeve"]), .sleeve)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Poster"]), .poster)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Tray"]), .inlay)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Watermark"]), .ignore)
        XCTAssertEqual(ArtworkRole.forCAATypes(["Booklet"]), .bookletPage)
        XCTAssertEqual(ArtworkRole.forCAATypes([]), .bookletPage)
    }

    func testEveryRoleHasAFilenameBase() {
        let bases = ArtworkRole.allCases.map(\.suggestedFilenameBase)
        XCTAssertEqual(Set(bases).count, bases.count, "Two roles writing the same base filename would collide on import")
        XCTAssertFalse(bases.contains(where: \.isEmpty))
    }
}
