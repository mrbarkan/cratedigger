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

    // MARK: - Patching after a write

    func testPatchAddsAndRemoves() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)
            store.save([track(named: "One"), track(named: "Two")], key: "IPOD")

            store.patch(
                key: "IPOD",
                adding: [track(named: "Three")],
                removingPaths: ["/Volumes/IPOD/Music/Two.mp3"]
            )

            XCTAssertEqual(store.load(key: "IPOD")?.map(\.track.title), ["One", "Three"])
        }
    }

    func testPatchRemovalIsCaseInsensitive() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)
            store.save([track(named: "Song")], key: "IPOD")

            // A FAT device answers to either spelling.
            store.patch(key: "IPOD", adding: [], removingPaths: ["/volumes/ipod/music/SONG.MP3"])

            XCTAssertEqual(store.load(key: "IPOD")?.count, 0)
        }
    }

    func testPatchReplacesARecordAtAWrittenPath() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)
            store.save([track(named: "Song")], key: "IPOD")
            // Same file on a FAT device, spelled differently by the new write.
            let rewritten = track(named: "SONG")

            // An overwrite in place: one record, the new one.
            store.patch(key: "IPOD", adding: [rewritten], removingPaths: [])

            XCTAssertEqual(store.load(key: "IPOD")?.map(\.track.title), ["SONG"])
        }
    }

    func testPatchedWorksOnACatalogInMemory() {
        let catalog = [track(named: "One"), track(named: "Two")]

        let patched = DeviceCatalogStore.patched(
            catalog,
            adding: [track(named: "Three"), track(named: "ONE")],
            removingPaths: ["/Volumes/IPOD/Music/Two.mp3"]
        )

        XCTAssertEqual(patched.map(\.track.title), ["Three", "ONE"])
    }

    func testPatchWithoutCatalogIsNoOp() throws {
        try withTemporaryDirectory(prefix: "catalog-store") { dir in
            let store = DeviceCatalogStore(directory: dir)

            store.patch(key: "IPOD", adding: [track(named: "One")], removingPaths: [])

            // Nothing to patch: the next browse scans the whole device.
            XCTAssertNil(store.load(key: "IPOD"))
            XCTAssertTrue(files(under: dir).isEmpty)
        }
    }

    func testWrittenTrackCarriesOutputFormat() {
        let source = sourceTrack(art: 1400, artSource: .embedded)
        let destination = URL(fileURLWithPath: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue/01 So What.mp3")
        let preset = ExternalDeviceTransferSettings(
            outputFormat: .mp3, bitrateKbps: 192, sampleRateHz: 44_100, artworkMaxDimension: 600
        ).conversionPreset

        let written = DeviceCatalogStore.writtenTrack(source: source, destination: destination, preset: preset)

        XCTAssertEqual(written.track.fileURL, destination)
        XCTAssertNotEqual(written.track.id, source.track.id, "a device record is not the library track")
        XCTAssertEqual(written.track.formatName, "MP3")
        XCTAssertEqual(written.track.bitrateKbps, 192)
        XCTAssertEqual(written.track.sampleRateHz, 44_100)
        XCTAssertEqual(written.track.title, "So What")
        XCTAssertEqual(written.track.trackNumber, 1)
        XCTAssertEqual(written.track.discNumber, 1)
        XCTAssertEqual(written.metadata.album, "Kind of Blue")
        XCTAssertEqual(written.metadata.albumArtist, "Miles Davis")
        // Re-embedded under the 600 px cap.
        XCTAssertEqual(written.track.artworkSource, .embedded)
        XCTAssertEqual(written.track.artworkDimensions, ArtworkDimensions(width: 600, height: 600))
    }

    func testWrittenTrackOfACopyKeepsTheSourceForm() {
        let source = sourceTrack(art: 1400, artSource: .embedded)
        let destination = URL(fileURLWithPath: "/Volumes/IPOD/Music/01 So What.flac")

        let written = DeviceCatalogStore.writtenTrack(source: source, destination: destination, preset: nil)

        XCTAssertEqual(written.track.formatName, "FLAC")
        XCTAssertEqual(written.track.bitrateKbps, 900)
        XCTAssertEqual(written.track.sampleRateHz, 96_000)
        XCTAssertEqual(written.track.artworkDimensions, ArtworkDimensions(width: 1400, height: 1400))
    }

    func testWrittenTrackNamesLosslessAndOpusOutputsLikeAScan() {
        let source = sourceTrack(art: nil, artSource: .none)
        let url = URL(fileURLWithPath: "/Volumes/IPOD/Music/x")
        func written(_ format: OutputFormat, bitDepth: Int? = nil) -> AudioTrack {
            let preset = ConversionPreset(
                id: "t", name: "t", outputFormat: format, bitrateKbps: 160,
                sampleRateHz: 44_100, channels: nil, bitDepth: bitDepth
            )
            return DeviceCatalogStore.writtenTrack(source: source, destination: url, preset: preset).track
        }

        XCTAssertEqual(written(.flac).formatName, "FLAC")
        XCTAssertNil(written(.flac).bitrateKbps, "lossless has no target bitrate")
        XCTAssertEqual(written(.aac).formatName, "AAC")
        XCTAssertEqual(written(.alac).formatName, "ALAC")
        XCTAssertEqual(written(.wav).formatName, "PCM_S16LE")
        XCTAssertEqual(written(.wav, bitDepth: 24).formatName, "PCM_S24LE")
        XCTAssertEqual(written(.aiff).formatName, "PCM_S16BE")
        XCTAssertEqual(written(.ogg).formatName, "VORBIS")
        XCTAssertEqual(written(.opus).formatName, "OPUS")
        XCTAssertEqual(written(.opus).sampleRateHz, 48_000, "libopus only writes 48 kHz")
    }

    func testWrittenTrackRecordsTheArtTheWriteLeft() {
        let url = URL(fileURLWithPath: "/Volumes/IPOD/Music/Kind of Blue/01 So What.mp3")
        func preset(_ mode: ArtworkMode, cap: Int? = 600) -> ConversionPreset? {
            var settings = ExternalDeviceTransferSettings(outputFormat: .mp3, artworkMaxDimension: cap)
            settings.artworkMode = mode
            return settings.conversionPreset
        }
        let embedded = sourceTrack(art: 1400, artSource: .embedded)
        let folder = sourceTrack(art: 1400, artSource: .folderImage)

        // Strip without a cover: nothing.
        let stripped = DeviceCatalogStore.writtenTrack(source: embedded, destination: url, preset: preset(.none))
        XCTAssertEqual(stripped.track.artworkSource, ArtworkSource.none)
        XCTAssertNil(stripped.track.artworkDimensions)
        XCTAssertNil(stripped.track.artworkHash)

        // Strip with a cover: what a rescan finds is the 400 px cover.jpg.
        let rockbox = DeviceCatalogStore.writtenTrack(
            source: embedded, destination: url, preset: preset(.none), writesFolderCoverArt: true)
        XCTAssertEqual(rockbox.track.artworkSource, .folderImage)
        XCTAssertEqual(rockbox.track.artworkDimensions, ArtworkDimensions(width: 400, height: 400))

        // Keep only carries the file's own art.
        let kept = DeviceCatalogStore.writtenTrack(source: folder, destination: url, preset: preset(.preserve, cap: nil))
        XCTAssertNil(kept.track.artworkDimensions)

        // A copy of a file whose art came from a folder image carries none.
        let copied = DeviceCatalogStore.writtenTrack(source: folder, destination: url, preset: nil)
        XCTAssertNil(copied.track.artworkDimensions)
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

    private func sourceTrack(art: Int?, artSource: ArtworkSource) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: "/Library/Miles Davis/Kind of Blue/01 So What.flac"),
            title: "So What", artist: "Miles Davis", album: "Kind of Blue",
            durationSeconds: 562, formatName: "FLAC", bitrateKbps: 900, sampleRateHz: 96_000,
            year: 1959, trackNumber: 1, trackTotal: 5, discNumber: 1,
            artworkSource: artSource, artworkHash: art == nil ? nil : "source-hash",
            artworkDimensions: art.map { ArtworkDimensions(width: $0, height: $0) }
        )
        let metadata = ConversionMetadata(
            title: "So What", artist: "Miles Davis", albumArtist: "Miles Davis",
            album: "Kind of Blue", trackNumber: 1, trackTotal: 5, discNumber: 1, year: 1959
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }
}
#endif
