#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Record Divider recordings on a convert-mode device run: each kept marker
/// is a file of its own, planned beside the reviewed plan.
final class DeviceRecordSlicesTests: XCTestCase {
    private var scratch: URL!
    private var device: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceRecordSlicesTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        device = scratch.appendingPathComponent("IPOD/Music/Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testSliceAlreadyThereIsCountedAndNeverWrittenAgain() throws {
        let side = recording()
        try "theirs".write(to: device.appendingPathComponent("01 First.mp3"), atomically: true, encoding: .utf8)

        let slices = DeviceRecordSlices(jobs: jobs(for: side), of: [side])

        XCTAssertEqual(slices.alreadyThere, 1)
        XCTAssertEqual(slices.copies.map(\.destinationURL.lastPathComponent), ["02 Second.mp3"])
        XCTAssertEqual(slices.copies.map(\.overwrites), [false])
        XCTAssertEqual(Set(slices.jobs.keys), [device.appendingPathComponent("02 Second.mp3").path])
    }

    func testEachSliceIsRecordedAsItsOwnTrack() throws {
        let side = recording()

        let slices = DeviceRecordSlices(jobs: jobs(for: side), of: [side])

        let second = try XCTUnwrap(slices.copies.last?.source)
        XCTAssertEqual(second.track.title, "Second")
        XCTAssertEqual(second.track.trackNumber, 2)
        XCTAssertEqual(second.track.durationSeconds, 210)
        XCTAssertEqual(second.track.fileURL, side.track.fileURL, "still cut from the recording")
    }

    func testMergedPlanCountsSlicesAlreadyThereAsPresent() throws {
        let side = recording()
        try "theirs".write(to: device.appendingPathComponent("01 First.mp3"), atomically: true, encoding: .utf8)
        let slices = DeviceRecordSlices(jobs: jobs(for: side), of: [side])
        let reviewed = DeviceTransferFilePlan(
            copies: [], deletionsByAlbum: [:], coverFolders: [:], skippedPresent: 3,
            leftAlone: 1, replacedAlbums: 0, keptBothAlbums: 0, gapAlbums: 0
        )

        let plan = slices.merged(into: reviewed, writesFolderCoverArt: true)

        XCTAssertEqual(plan.copies.count, 1)
        XCTAssertEqual(plan.skippedPresent, 4)
        XCTAssertEqual(plan.leftAlone, 1)
        XCTAssertEqual(plan.coverFolders.keys.map(\.lastPathComponent), ["Album"])
        XCTAssertTrue(slices.merged(into: reviewed, writesFolderCoverArt: false).coverFolders.isEmpty)
    }

    // MARK: - Fixtures

    private func recording() -> LoadedTrack {
        let url = scratch.appendingPathComponent("Library/Side A.flac")
        let audio = AudioTrack(fileURL: url, title: "Side A", artist: "Artist", album: "Album", durationSeconds: 410)
        return LoadedTrack(
            track: audio,
            metadata: ConversionMetadata(title: "Side A", artist: "Artist", album: "Album"),
            recordMarkers: [
                RecordMarker(startSeconds: 0, endSeconds: 200, title: "First"),
                RecordMarker(startSeconds: 200, endSeconds: 410, title: "Second")
            ]
        )
    }

    /// The slice jobs the conversion planner makes for `track`, at their
    /// natural names in the device's album folder.
    private func jobs(for track: LoadedTrack) -> [ConversionJob] {
        RecordTrackPlanner.trackPlans(for: track).map { plan in
            ConversionJob(sourceURL: track.track.fileURL,
                          destinationURL: device.appendingPathComponent("\(plan.baseName).mp3"),
                          metadata: plan.metadata,
                          startSeconds: plan.startSeconds, endSeconds: plan.endSeconds)
        }
    }
}
#endif
