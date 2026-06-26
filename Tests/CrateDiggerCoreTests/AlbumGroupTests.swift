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
}
#endif
