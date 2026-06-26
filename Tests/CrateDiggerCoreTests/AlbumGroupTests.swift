#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class AlbumGroupTests: XCTestCase {
    func testAlbumGroupCodableRoundTrip() throws {
        let key = AlbumFolderKey(artistBucket: "Daft Punk", album: "Discovery", year: "2001")
        let jp = AlbumFolderKey(artistBucket: "Daft Punk", album: "Discovery (JP)", year: "2001")
        let group = AlbumGroup(
            id: "g1", name: "Discovery", artistID: "daft punk", originalYear: 1999,
            primaryKey: key,
            members: [VersionMember(key: key, editionLabel: "US FLAC"),
                      VersionMember(key: jp, editionLabel: "JP FLAC")]
        )
        let data = try JSONEncoder().encode(group)
        let back = try JSONDecoder().decode(AlbumGroup.self, from: data)
        XCTAssertEqual(back, group)
        XCTAssertEqual(back.members.count, 2)
        XCTAssertEqual(back.primaryKey, key)
    }

    func testAlbumVersionFieldsAndWithEdition() {
        let plain = Album(id: "a", artistID: "x", artistName: "X", title: "T",
                          year: 2001, artworkHash: nil, tracks: [])
        XCTAssertFalse(plain.isVersionGroup)
        XCTAssertNil(plain.editionLabel)

        let labeled = plain.with(editionLabel: "JP Vinyl")
        XCTAssertEqual(labeled.editionLabel, "JP Vinyl")
        XCTAssertEqual(labeled.id, "a")

        let release = Album(id: "g", artistID: "x", artistName: "X", title: "T",
                            year: 2001, artworkHash: nil, tracks: [],
                            versions: [plain], originalYear: 1975)
        XCTAssertTrue(release.isVersionGroup)
        XCTAssertEqual(release.originalYear, 1975)
        XCTAssertEqual(release.versions?.count, 1)
    }
}
#endif
