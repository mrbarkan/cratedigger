import XCTest
@testable import CrateDiggerCore

final class DeviceSyncQueueStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: DeviceSyncQueueStore!
    private let profileID = UUID()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-syncqueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DeviceSyncQueueStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTrip() {
        let entry = makeEntry(relativePath: "Music/Artist/Album/01 Song.m4a")
        store.save([entry], profileID: profileID)
        let loaded = store.load(profileID: profileID)
        XCTAssertEqual(loaded, [entry])
    }

    func testLoadMissingProfileReturnsEmpty() {
        XCTAssertEqual(store.load(profileID: UUID()), [])
    }

    func testRemoveDeletesQueueAndStagingTree() throws {
        let entry = makeEntry(relativePath: "Music/A/01.m4a")
        store.save([entry], profileID: profileID)
        let staged = store.stagedFileURL(for: entry, profileID: profileID)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged)

        store.remove(profileID: profileID)

        XCTAssertEqual(store.load(profileID: profileID), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.stagingDirectory(for: profileID).path))
    }

    func testRemoveStagedFilePrunesEmptyParents() throws {
        let entry = makeEntry(relativePath: "Music/Artist/Album/01 Song.m4a")
        let staged = store.stagedFileURL(for: entry, profileID: profileID)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged)
        // A sibling file elsewhere in staging must survive the prune.
        let sibling = makeEntry(relativePath: "Music/Other/02.m4a")
        let siblingURL = store.stagedFileURL(for: sibling, profileID: profileID)
        try FileManager.default.createDirectory(
            at: siblingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: siblingURL)

        store.removeStagedFile(for: entry, profileID: profileID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // Emptied Album + Artist dirs pruned…
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.deletingLastPathComponent().path))
        // …but the sibling and its branch survive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testSweepOrphansDeletesOnlyUnknownProfiles() throws {
        let keepID = UUID(), orphanID = UUID()
        store.save([makeEntry(relativePath: "a.m4a")], profileID: keepID)
        store.save([makeEntry(relativePath: "b.m4a")], profileID: orphanID)
        try FileManager.default.createDirectory(
            at: store.stagingDirectory(for: orphanID), withIntermediateDirectories: true)

        store.sweepOrphans(validProfileIDs: [keepID])

        XCTAssertEqual(store.load(profileID: keepID).count, 1)
        XCTAssertEqual(store.load(profileID: orphanID), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.stagingDirectory(for: orphanID).path))
    }

    // MARK: - Review decisions

    func testLegacyQueueEntryDecodesNilDecision() throws {
        let entries = try JSONDecoder().decode([DeviceSyncQueueEntry].self, from: Data(Self.legacyQueueJSON.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].decision)
        XCTAssertEqual(entries[0].destinationRelativePath, "Music/Miles Davis/Kind of Blue/01 So What.mp3")
        XCTAssertEqual(entries[0].track.track.title, "So What")
    }

    func testDecisionRoundTrips() {
        var replace = makeEntry(relativePath: "Music/A/01.m4a")
        replace.decision = .replace
        var keepBoth = makeEntry(relativePath: "Music/B/01.m4a")
        keepBoth.decision = .keepBoth
        var leave = makeEntry(relativePath: "Music/C/01.m4a")
        leave.decision = .leave
        let undecided = makeEntry(relativePath: "Music/D/01.m4a")

        store.save([replace, keepBoth, leave, undecided], profileID: profileID)

        XCTAssertEqual(store.load(profileID: profileID).map(\.decision), [.replace, .keepBoth, .leave, nil])
    }

    /// One entry as the encoder wrote it before `decision` existed.
    private static let legacyQueueJSON = """
    [
      {
        "destinationRelativePath" : "Music\\/Miles Davis\\/Kind of Blue\\/01 So What.mp3",
        "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3304",
        "isStaged" : false,
        "queuedAt" : 0,
        "sourceModifiedAt" : 0,
        "track" : {
          "metadata" : {
            "album" : "Kind of Blue",
            "artist" : "Miles Davis",
            "customTagPairs" : [

            ],
            "title" : "So What",
            "trackNumber" : 1
          },
          "track" : {
            "album" : "Kind of Blue",
            "artist" : "Miles Davis",
            "artworkSource" : "none",
            "durationSeconds" : 0,
            "fileURL" : "file:\\/\\/\\/Src\\/Kind%20of%20Blue\\/01%20So%20What.flac",
            "formatName" : "FLAC",
            "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3303",
            "title" : "So What",
            "trackNumber" : 1
          }
        }
      }
    ]
    """

    private func makeEntry(relativePath: String) -> DeviceSyncQueueEntry {
        let url = URL(fileURLWithPath: "/tmp/source/\(relativePath)")
        let track = AudioTrack(
            fileURL: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "Artist",
            album: "Album"
        )
        let metadata = ConversionMetadata(
            artist: "Artist", albumArtist: "Artist", album: "Album", year: 2001)
        return DeviceSyncQueueEntry(
            id: UUID(),
            track: LoadedTrack(track: track, metadata: metadata),
            destinationRelativePath: relativePath,
            isStaged: true,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_000_000),
            queuedAt: Date(timeIntervalSince1970: 2_000_000)
        )
    }
}
