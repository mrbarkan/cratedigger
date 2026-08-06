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

    /// The store is written in sorted path order, so an unchanged library
    /// re-serializes to byte-identical output instead of being reshuffled by
    /// whatever order the dictionary happened to hash into this launch. Without
    /// it, delta-based backup and sync see the whole index as changed on every
    /// save. 60 tracks makes an accidentally-sorted dictionary order vanishingly
    /// unlikely.
    func testSaveWritesSortedPathOrderSoUnchangedLibrariesReserializeIdentically() throws {
        try withTemporaryDirectory(prefix: "trackstore") { dir in
            // Build the tracks once and reuse the instances: AudioTrack carries a
            // freshly generated `id`, so rebuilding them would differ regardless
            // of ordering and prove nothing.
            let paths = (0..<60).map { "/m/\(UUID().uuidString)-\($0).flac" }
            let tracks = paths.enumerated().map { track($1, title: "T\($0)") }

            let url = dir.appendingPathComponent("library.cdtracks")
            let store = TrackStore(fileURL: url)
            for entry in tracks { store.upsert(entry) }
            try store.save()

            let written = try JSONDecoder().decode([LoadedTrack].self, from: Data(contentsOf: url))
            let writtenPaths = written.map { TrackStore.key(for: $0.track.fileURL) }
            XCTAssertEqual(writtenPaths, writtenPaths.sorted(), "store must persist in sorted path order")
            XCTAssertEqual(Set(writtenPaths), Set(paths), "sorting must not drop or add tracks")

            // The same tracks inserted in a different order must produce the exact
            // same bytes — that is the property backups and delta sync rely on.
            let shuffledURL = dir.appendingPathComponent("shuffled.cdtracks")
            let shuffledStore = TrackStore(fileURL: shuffledURL)
            for entry in tracks.shuffled() { shuffledStore.upsert(entry) }
            try shuffledStore.save()

            XCTAssertEqual(
                try Data(contentsOf: url), try Data(contentsOf: shuffledURL),
                "same library inserted in a different order must serialize identically"
            )
        }
    }

    /// A save with nothing to write must not touch the file. Re-upserting the
    /// same tracks (what saving any crate does) has to leave the store clean.
    func testSaveSkipsWriteWhenNothingChanged() throws {
        try withTemporaryDirectory(prefix: "trackstore") { dir in
            let url = dir.appendingPathComponent("library.cdtracks")
            let store = TrackStore(fileURL: url)
            let a = track("/m/a.flac", title: "A")
            store.upsert(a)
            try store.save()

            let firstWrite = try modificationDate(of: url)

            // Re-upserting identical values changes nothing.
            store.upsert(a)
            try store.save()
            XCTAssertEqual(try modificationDate(of: url), firstWrite, "clean save must not rewrite the file")

            // Removing something absent changes nothing either.
            store.remove(path: "/m/not-here.flac")
            try store.save()
            XCTAssertEqual(try modificationDate(of: url), firstWrite, "no-op remove must not rewrite the file")

            // A real change does get written.
            store.upsert(track("/m/b.flac", title: "B"))
            try store.save()
            let reopened = TrackStore(fileURL: url)
            XCTAssertEqual(reopened.count, 2)
        }
    }

    /// An index that exists but won't decode must not be silently replaced by
    /// whatever is in memory — that would turn a corrupt file into a lost library.
    func testSaveRefusesToOverwriteAnUnreadableStore() throws {
        try withTemporaryDirectory(prefix: "trackstore") { dir in
            let url = dir.appendingPathComponent("library.cdtracks")
            let garbage = Data("{ this is not a track index".utf8)
            try garbage.write(to: url)

            let store = TrackStore(fileURL: url)
            XCTAssertEqual(store.count, 0, "an unreadable store loads empty")

            store.upsert(track("/m/a.flac", title: "A"))
            XCTAssertThrowsError(try store.save()) { error in
                guard case TrackStoreError.unreadableStore = error else {
                    return XCTFail("expected unreadableStore, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), garbage, "the unreadable file must be left intact")
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
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
