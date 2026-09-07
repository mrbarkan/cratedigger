#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The catalog filename is built from `MountedDevice.catalogKey`, which is the
/// volume's UUID when it has one and **the volume's name** when it does not.
/// A name is whatever the owner typed when they formatted the thing, so it is
/// the one input here that is not ours, and it decides a path.
final class DeviceCatalogStoreTests: XCTestCase {

    func testRoundTripsACatalog() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)
            let tracks = [track(named: "One"), track(named: "Two")]

            store.save(tracks, key: "ABC-123")
            let loaded = store.load(key: "ABC-123")

            XCTAssertEqual(loaded?.count, 2)
            XCTAssertEqual(loaded?.map(\.track.title), ["One", "Two"])
        }
    }

    func testUnknownKeyLoadsNothing() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            XCTAssertNil(DeviceCatalogStore(directory: dir).load(key: "never-saved"))
        }
    }

    func testRemoveDropsTheCatalog() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)
            store.save([track(named: "One")], key: "ABC-123")
            XCTAssertNotNil(store.load(key: "ABC-123"))

            store.remove(key: "ABC-123")

            XCTAssertNil(store.load(key: "ABC-123"))
        }
    }

    // MARK: - The name is not ours

    func testAVolumeNamedLikeATraversalStaysInsideTheDirectory() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)

            store.save([track(named: "One")], key: "../../../../tmp/pwned")

            let written = files(under: dir)
            XCTAssertEqual(written.count, 1)
            // One flat file directly inside the store's directory: every "/"
            // became "_", so there is nothing left to climb with.
            XCTAssertEqual(written.first?.deletingLastPathComponent(), resolved(dir))
            XCTAssertFalse(written.first?.lastPathComponent.contains("/") ?? true)
            XCTAssertNotNil(store.load(key: "../../../../tmp/pwned"))
        }
    }

    func testSeparatorsInAVolumeNameCannotSplitThePath() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)

            store.save([track(named: "One")], key: "a/b/c")

            // One flat file, not a nested a/b/ tree.
            let written = files(under: dir)
            XCTAssertEqual(written.count, 1)
            XCTAssertEqual(written.first?.deletingLastPathComponent(), resolved(dir))
            XCTAssertNil(store.load(key: "a-b-c"), "the mapping is not reversible by guesswork")
            XCTAssertNotNil(store.load(key: "a/b/c"), "but it is stable for the same key")
        }
    }

    func testTwoNamesThatCleanToTheSameFileShareIt() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)

            // Deliberate documentation of a real collision: the sanitiser maps
            // every disallowed character to "_", so these are one file. Two
            // iPods named this way would share a catalog. Acceptable because a
            // volume UUID is preferred whenever there is one, and a stale
            // catalog only costs a RESCAN — but it should not surprise anyone.
            store.save([track(named: "First")], key: "My iPod!")
            store.save([track(named: "Second")], key: "My iPod?")

            XCTAssertEqual(files(under: dir).count, 1)
            XCTAssertEqual(store.load(key: "My iPod!")?.first?.track.title, "Second")
        }
    }

    func testAnEmptyKeyStillWritesSomewhereSensible() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)

            store.save([track(named: "One")], key: "")

            XCTAssertEqual(store.load(key: "")?.count, 1)
            XCTAssertEqual(files(under: dir).first?.lastPathComponent, "device.cdtracks")
        }
    }

    // MARK: - Helpers

    /// `/var` is a symlink to `/private/var`, and the enumerator hands back the
    /// resolved form while the URL we passed in keeps the short one. Compare
    /// like for like or the assertion fails for a reason that is not the point.
    private func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func files(under directory: URL) -> [URL] {
        let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (all?.allObjects as? [URL] ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { resolved($0) }
    }

    private func track(named title: String) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: "/Volumes/IPOD/Music/\(title).mp3"),
            title: title, artist: "Artist", album: "Album",
            year: 1999, trackNumber: 1, discNumber: 1,
            artworkSource: .none, artworkHash: nil
        )
        return LoadedTrack(track: audio, metadata: ConversionMetadata(title: title))
    }
}
#endif
