import XCTest
@testable import CrateDiggerCore

final class TrackStoreTests: XCTestCase {

    private func track(_ path: String, title: String, artworkBytes: Data? = nil) -> LoadedTrack {
        let artwork = artworkBytes.map {
            ArtworkAsset(source: .embedded, hash: "h-\(title)", dimensions: ArtworkDimensions(width: 1, height: 1), data: $0)
        }
        return LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: title),
            metadata: ConversionMetadata(title: title, artwork: artwork)
        )
    }

    func testUpsertAndResolveByPath() {
        try? withTemporaryDirectory(prefix: "trackstore") { dir in
            let store = TrackStore(fileURL: dir.appendingPathComponent("library.cdtracks"))
            store.upsert(track("/Volumes/M/a.flac", title: "A"))
            store.upsert(track("/Volumes/M/b.flac", title: "B"))
            XCTAssertEqual(store.count, 2)
            XCTAssertEqual(store.track(path: "/Volumes/M/a.flac")?.track.title, "A")
            XCTAssertNil(store.track(path: "/Volumes/M/missing.flac"))
        }
    }

    func testMembershipPreservesOrderAndSkipsMissing() {
        try? withTemporaryDirectory(prefix: "trackstore") { dir in
            let store = TrackStore(fileURL: dir.appendingPathComponent("library.cdtracks"))
            store.upsert(track("/m/a.flac", title: "A"))
            store.upsert(track("/m/b.flac", title: "B"))
            let resolved = store.tracks(paths: ["/m/b.flac", "/m/gone.flac", "/m/a.flac"])
            XCTAssertEqual(resolved.map(\.track.title), ["B", "A"])  // order kept, missing skipped
        }
    }

    func testSamePathStoredOnce() {
        try? withTemporaryDirectory(prefix: "trackstore") { dir in
            let store = TrackStore(fileURL: dir.appendingPathComponent("library.cdtracks"))
            store.upsert(track("/m/a.flac", title: "first"))
            store.upsert(track("/m/a.flac", title: "second"))   // same file -> dedup, latest wins
            XCTAssertEqual(store.count, 1)
            XCTAssertEqual(store.track(path: "/m/a.flac")?.track.title, "second")
        }
    }

    func testPersistsAcrossInstancesWithoutArtworkBytes() {
        try? withTemporaryDirectory(prefix: "trackstore") { dir in
            let url = dir.appendingPathComponent("library.cdtracks")
            do {
                let store = TrackStore(fileURL: url)
                store.upsert(track("/m/a.flac", title: "A", artworkBytes: Data([1, 2, 3, 4])))
                try? store.save()
            }
            // A fresh instance (relaunch) resolves the track, and the persisted
            // file carries no artwork bytes (those live in ArtworkStore by hash).
            let reopened = TrackStore(fileURL: url)
            XCTAssertEqual(reopened.track(path: "/m/a.flac")?.track.title, "A")
            XCTAssertEqual(reopened.track(path: "/m/a.flac")?.metadata.artwork?.hash, "h-A")
            XCTAssertTrue(reopened.track(path: "/m/a.flac")?.metadata.artwork?.data.isEmpty ?? false)

            let raw = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            XCTAssertFalse(raw.contains("\"data\""), "track store must not persist artwork bytes")
        }
    }

    func testRemove() {
        try? withTemporaryDirectory(prefix: "trackstore") { dir in
            let store = TrackStore(fileURL: dir.appendingPathComponent("library.cdtracks"))
            store.upsert(track("/m/a.flac", title: "A"))
            store.remove(path: "/m/a.flac")
            XCTAssertEqual(store.count, 0)
        }
    }
}
