#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class AlbumGroupStoreTests: XCTestCase {
    private func freshStore() -> AlbumGroupStore {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return AlbumGroupStore(prefs: PreferencesStore(defaults: d))
    }

    private func make(_ id: String) -> AlbumGroup {
        let k = AlbumFolderKey(artistBucket: "A", album: "Rec \(id)", year: "2001")
        return AlbumGroup(id: id, name: "Rec", artistID: "a", originalYear: 1999,
                          primaryKey: k, members: [VersionMember(key: k)])
    }

    func testEmptyByDefault() {
        XCTAssertTrue(freshStore().all().isEmpty)
    }

    func testSaveAndLoadRoundTrip() {
        let s = freshStore()
        s.save([make("g1"), make("g2")])
        XCTAssertEqual(s.all().map(\.id), ["g1", "g2"])
    }

    func testUpsertReplacesById() {
        let s = freshStore()
        s.upsert(make("g1"))
        var g = make("g1"); g.name = "Renamed"
        s.upsert(g)
        XCTAssertEqual(s.all().count, 1)
        XCTAssertEqual(s.all().first?.name, "Renamed")
    }

    func testRemove() {
        let s = freshStore()
        s.save([make("g1"), make("g2")])
        s.remove(id: "g1")
        XCTAssertEqual(s.all().map(\.id), ["g2"])
    }

    func testSavingEmptyClearsStorage() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let prefs = PreferencesStore(defaults: d)
        AlbumGroupStore(prefs: prefs).save([make("g1")])
        AlbumGroupStore(prefs: prefs).save([])
        XCTAssertNil(prefs.albumGroupsData)
    }
}
#endif
