#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class StreamDownloadLinkTests: XCTestCase {
    private func stream(_ id: String, kind: StreamKind = .mix, path: String? = nil) -> StreamSource {
        var s = StreamSource(id: id, url: "https://youtu.be/\(id)", title: id, channel: "Ch",
                             kind: kind, hue: 0, addedAt: Date(timeIntervalSince1970: 0))
        s.downloadedPath = path
        return s
    }

    func testBlobFromBeforeDownloadsStillDecodes() throws {
        let old = #"[{"id":"a","url":"u","title":"t","channel":"c","kind":"mix","hue":1,"provider":"youtube","addedAt":0}]"#
        let decoded = try JSONDecoder().decode([StreamSource].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].downloadedPath)
    }

    func testDownloadedNeedsThePathAndTheFile() {
        XCTAssertFalse(stream("a").isDownloaded(fileExists: { _ in true }))
        XCTAssertFalse(stream("a", path: "/x.m4a").isDownloaded(fileExists: { _ in false }))
        XCTAssertTrue(stream("a", path: "/x.m4a").isDownloaded(fileExists: { $0 == "/x.m4a" }))
    }

    func testDownloadsCategoryIsAFilterNotAHome() {
        let s = stream("a", path: "/x.m4a")
        XCTAssertEqual(RadioCategory.of(s), .youtubeRecords)   // its home does not change
        XCTAssertTrue(RadioCategory.youtubeRecords.contains(s))
        XCTAssertEqual(RadioCategory.downloaded.title, "Downloads")
    }

    func testRepointAndSetDownload() {
        let store = StreamStore(prefs: PreferencesStore(defaults: makeScratchDefaults()))
        store.save([stream("a"), stream("b", path: "/old/b.m4a")])

        XCTAssertEqual(store.setDownload(path: "/lib/a.m4a", forStreamID: "a").first { $0.id == "a" }?.downloadedPath, "/lib/a.m4a")
        XCTAssertEqual(store.repointDownload(from: "/old/b.m4a", to: "/new/b.m4a").first { $0.id == "b" }?.downloadedPath, "/new/b.m4a")
        XCTAssertNil(store.setDownload(path: nil, forStreamID: "a").first { $0.id == "a" }?.downloadedPath)
        XCTAssertEqual(store.repointDownload(from: "/nobody", to: "/x").count, 2)   // a miss changes nothing
    }
}
#endif
