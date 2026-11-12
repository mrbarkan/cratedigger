#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The offline queue's side of the device review: a last-known catalog moved
/// onto the staging tree, the entries a queue-time plan adds, the answers
/// those entries carry back to SYNC, and where SYNC reads each entry's bytes.
final class DeviceSyncQueuePlannerTests: XCTestCase {
    private var scratch: URL!
    private var staging: URL!
    /// Where the device was mounted when its catalog was saved. Never created:
    /// the catalog is all a queue-time review reads of it.
    private let deviceRoot = URL(fileURLWithPath: "/Volumes/IPOD", isDirectory: true)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceSyncQueuePlannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch = base.resolvingSymlinksInPath()
        staging = scratch.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Rebasing the catalog

    func testRebasedCatalogKeepsRelativePathsUnderTheStagingRoot() {
        let onDevice = track(number: 1, path: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue/01 Track 1.flac")

        let rebased = DeviceSyncQueuePlanner.catalog([onDevice], rebasedFrom: deviceRoot, onto: staging)

        XCTAssertEqual(rebased.map(\.track.fileURL.path),
                       [staging.appendingPathComponent("Music/Miles Davis/Kind of Blue/01 Track 1.flac").path])
        XCTAssertEqual(rebased.first?.track.id, onDevice.track.id)
        XCTAssertEqual(rebased.first?.track.formatName, "FLAC")
        XCTAssertEqual(rebased.first?.metadata, onDevice.metadata)
    }

    func testRebasedCatalogDropsTracksOutsideTheDeviceRoot() {
        let catalog = [
            track(number: 1, path: "/Volumes/IPOD 1/Music/A/01 Track 1.flac"),
            track(number: 2, path: "/Volumes/OTHER/Music/A/02 Track 2.flac"),
            track(number: 3, path: "/Volumes/IPOD")
        ]

        XCTAssertEqual(DeviceSyncQueuePlanner.catalog(catalog, rebasedFrom: deviceRoot, onto: staging), [])
    }

    func testRebasedCatalogMatchesTheRootIgnoringCase() {
        let onDevice = track(number: 1, path: "/Volumes/ipod/Music/A/01 Track 1.flac")

        let rebased = DeviceSyncQueuePlanner.catalog([onDevice], rebasedFrom: deviceRoot, onto: staging)

        XCTAssertEqual(rebased.map(\.track.fileURL.path),
                       [staging.appendingPathComponent("Music/A/01 Track 1.flac").path])
    }

    // MARK: - Queue-time review

    func testQueueTimeReviewFillsGapsInTheLastKnownFolder() throws {
        let profile = copyProfile()
        // Filed under an older template; the profile now plans Artist/Year/Album.
        let catalog = [1, 2].map {
            track(number: $0, path: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue/0\($0) Track \($0).flac")
        }
        let review = DeviceTransferResolver().review(
            sending: sent([1, 2, 3]),
            catalog: DeviceSyncQueuePlanner.catalog(catalog, rebasedFrom: deviceRoot, onto: staging),
            profile: profile,
            mountedAt: staging,
            leftAlone: []
        )
        XCTAssertEqual(review.albums.map(\.status), [.gaps])

        let plan = try DeviceTransferResolver().resolve(review, decisions: [:], profile: profile, mountedAt: staging)
        let entries = DeviceSyncQueuePlanner.entries(for: plan, stagingRoot: staging, decisions: [:], queued: [])

        XCTAssertEqual(entries.map(\.destinationRelativePath), ["Music/Miles Davis/Kind of Blue/03 Track 3.flac"])
        XCTAssertEqual(entries.map(\.decision), [nil])
        XCTAssertEqual(entries.map(\.isStaged), [false])
        XCTAssertEqual(entries.map(\.sourceModifiedAt), [.distantPast])
        XCTAssertEqual(plan.skippedPresent, 2, "the two already there are not queued")
    }

    func testQueueTimeAnswerIsRecordedOnTheAlbumsEntries() throws {
        let profile = copyProfile()
        let catalog = [1, 2].map {
            track(number: $0, format: "MP3", path: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue/0\($0) Track \($0).mp3")
        }
        let review = DeviceTransferResolver().review(
            sending: sent([1, 2]),
            catalog: DeviceSyncQueuePlanner.catalog(catalog, rebasedFrom: deviceRoot, onto: staging),
            profile: profile,
            mountedAt: staging,
            leftAlone: []
        )
        let identity = try XCTUnwrap(review.needingDecision.first?.identity)

        let decisions: [DeviceAlbumIdentity: DeviceAlbumDecision] = [identity: .replace]
        let plan = try DeviceTransferResolver().resolve(review, decisions: decisions, profile: profile, mountedAt: staging)
        let entries = DeviceSyncQueuePlanner.entries(for: plan, stagingRoot: staging, decisions: decisions, queued: [])

        XCTAssertEqual(entries.map(\.destinationRelativePath), [
            "Music/Miles Davis/Kind of Blue/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue/02 Track 2.flac"
        ])
        XCTAssertEqual(entries.map(\.decision), [.replace, .replace])
    }

    func testLeaveItAlbumIsNotQueued() throws {
        let profile = copyProfile()
        let catalog = [track(number: 1, format: "MP3", path: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue/01 Track 1.mp3")]
        let review = DeviceTransferResolver().review(
            sending: sent([1]),
            catalog: DeviceSyncQueuePlanner.catalog(catalog, rebasedFrom: deviceRoot, onto: staging),
            profile: profile,
            mountedAt: staging,
            leftAlone: []
        )
        let identity = try XCTUnwrap(review.needingDecision.first?.identity)

        let decisions: [DeviceAlbumIdentity: DeviceAlbumDecision] = [identity: .leave]
        let plan = try DeviceTransferResolver().resolve(review, decisions: decisions, profile: profile, mountedAt: staging)

        XCTAssertEqual(DeviceSyncQueuePlanner.entries(for: plan, stagingRoot: staging, decisions: decisions, queued: []), [])
        XCTAssertEqual(plan.leftAlone, 1)
    }

    // MARK: - Entries

    func testEntriesSkipSourcesAlreadyQueued() throws {
        let profile = copyProfile()
        let tracks = sent([1, 2])
        let review = DeviceTransferResolver().review(sending: tracks, catalog: [], profile: profile,
                                                     mountedAt: staging, leftAlone: [])
        let plan = try DeviceTransferResolver().resolve(review, decisions: [:], profile: profile, mountedAt: staging)
        let queued = DeviceSyncQueueEntry(track: tracks[0], destinationRelativePath: "Music/Elsewhere/01.flac",
                                          isStaged: false, sourceModifiedAt: .distantPast)

        let entries = DeviceSyncQueuePlanner.entries(for: plan, stagingRoot: staging, decisions: [:], queued: [queued])

        XCTAssertEqual(entries.map(\.track.track.fileURL), [tracks[1].track.fileURL])
    }

    func testEntriesStepPastAPathTheQueueAlreadyHolds() throws {
        let profile = copyProfile()
        let review = DeviceTransferResolver().review(sending: sent([1]), catalog: [], profile: profile,
                                                     mountedAt: staging, leftAlone: [])
        let plan = try DeviceTransferResolver().resolve(review, decisions: [:], profile: profile, mountedAt: staging)
        // Another source file, queued earlier, planned onto the same name.
        let other = track(number: 1, path: scratch.appendingPathComponent("Other/01 Track 1.flac").path)
        let queued = DeviceSyncQueueEntry(track: other,
                                          destinationRelativePath: "music/miles davis/1959/kind of blue/01 Track 1.flac",
                                          isStaged: false, sourceModifiedAt: .distantPast)

        let entries = DeviceSyncQueuePlanner.entries(for: plan, stagingRoot: staging, decisions: [:], queued: [queued])

        XCTAssertEqual(entries.map(\.destinationRelativePath),
                       ["Music/Miles Davis/1959/Kind of Blue/01 Track 1 (2).flac"])
    }

    // MARK: - Stored decisions

    func testStoredDecisionsArePerAlbum() {
        let kindOfBlue = sent([1, 2])
        let blueTrain = sent([1], folder: "Src/Blue Train", album: "Blue Train")
        let entries = [
            entry(kindOfBlue[0], .replace),
            entry(kindOfBlue[1], nil),
            entry(blueTrain[0], .keepBoth)
        ]

        XCTAssertEqual(DeviceSyncQueuePlanner.storedDecisions(for: entries), [
            DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue"): .replace,
            DeviceAlbumIdentity(artist: "Miles Davis", album: "Blue Train"): .keepBoth
        ])
    }

    func testConflictingStoredDecisionsAreAskedAgain() {
        let tracks = sent([1, 2])
        let entries = [entry(tracks[0], .replace), entry(tracks[1], .keepBoth)]

        XCTAssertEqual(DeviceSyncQueuePlanner.storedDecisions(for: entries), [:])
    }

    // MARK: - Where SYNC reads an entry

    func testFreshBakeIsCopied() {
        let baked = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(source(staged: true, bakedAt: baked, stagedExists: true, sourceModified: baked), .staged)
        // The bake stands on its own once the source is gone.
        XCTAssertEqual(source(staged: true, bakedAt: baked, stagedExists: true, sourceModified: nil), .staged)
    }

    func testStaleBakeIsConvertedAgain() {
        XCTAssertEqual(source(staged: true, bakedAt: Date(timeIntervalSince1970: 1_000), stagedExists: true,
                              sourceModified: Date(timeIntervalSince1970: 2_000)), .convert)
    }

    func testBakeInAnotherFormatIsConvertedAgain() {
        let baked = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(source(staged: true, bakedAt: baked, stagedExists: true, sourceModified: baked,
                              stagedName: "01 Track 1.m4a", destinationName: "01 Track 1.mp3"), .convert)
    }

    func testMissingBakeFallsBackToTheSource() {
        let baked = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(source(staged: true, bakedAt: baked, stagedExists: false, sourceModified: baked), .convert)
        guard case .unavailable = source(staged: true, bakedAt: baked, stagedExists: false, sourceModified: nil) else {
            return XCTFail("no bake and no source: nothing to write")
        }
    }

    func testUnbakedEntryIsConvertedOrCopied() {
        XCTAssertEqual(source(staged: false, stagedExists: false, sourceModified: .distantPast), .convert)
        XCTAssertEqual(source(staged: false, stagedExists: false, sourceModified: .distantPast, converts: false), .copy)
        guard case .unavailable = source(staged: false, stagedExists: false, sourceModified: nil) else {
            return XCTFail("a missing source can't be written")
        }
    }

    // MARK: - Fixtures

    private func copyProfile() -> ExternalDeviceProfile {
        var profile = ExternalDeviceProfile.genericStorage(name: "Test")
        profile.transferSettings.mode = .copyOriginals
        profile.transferSettings.folderStructureMode = .metadataTemplate
        return profile
    }

    private func source(
        staged: Bool,
        bakedAt: Date = .distantPast,
        stagedExists: Bool,
        sourceModified: Date?,
        converts: Bool = true,
        stagedName: String = "01 Track 1.mp3",
        destinationName: String = "01 Track 1.mp3"
    ) -> DeviceSyncQueuePlanner.SyncSource {
        let entry = DeviceSyncQueueEntry(track: sent([1])[0], destinationRelativePath: "Music/\(stagedName)",
                                         isStaged: staged, sourceModifiedAt: bakedAt)
        return DeviceSyncQueuePlanner.source(
            for: entry,
            stagedURL: staging.appendingPathComponent("Music/\(stagedName)"),
            destination: URL(fileURLWithPath: "/Volumes/IPOD/Music/\(destinationName)"),
            converts: converts,
            stagedFileExists: stagedExists,
            sourceModifiedAt: sourceModified
        )
    }

    private func entry(_ track: LoadedTrack, _ decision: DeviceAlbumDecision?) -> DeviceSyncQueueEntry {
        DeviceSyncQueueEntry(track: track, destinationRelativePath: track.track.fileURL.lastPathComponent,
                             isStaged: false, sourceModifiedAt: .distantPast, decision: decision)
    }

    /// Library tracks being sent; their files are never read.
    private func sent(_ numbers: [Int], folder: String = "Src/Kind of Blue", album: String = "Kind of Blue") -> [LoadedTrack] {
        numbers.map { number in
            track(number: number, album: album,
                  path: scratch.appendingPathComponent("\(folder)/0\(number) Track \(number).flac").path,
                  year: 1959)
        }
    }

    private func track(
        number: Int,
        album: String = "Kind of Blue",
        format: String = "FLAC",
        path: String,
        year: Int? = nil
    ) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: path),
            title: "Track \(number)",
            artist: "Miles Davis",
            album: album,
            formatName: format,
            bitrateKbps: format == "MP3" ? 128 : 900,
            sampleRateHz: 44_100,
            year: year,
            trackNumber: number
        )
        let metadata = ConversionMetadata(
            title: "Track \(number)", artist: "Miles Davis", album: album, trackNumber: number, year: year
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }
}
#endif
