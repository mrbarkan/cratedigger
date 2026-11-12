import XCTest
@testable import CrateDiggerCore

final class PodBoxNextStepsTests: XCTestCase {
    private let update = "Eject the iPod. PodBox adds the new music when it restarts. If it does not appear: Settings ▸ Library ▸ Maintenance ▸ Update Database."
    private let artCache = "Then on the iPod: Settings ▸ Library ▸ Maintenance ▸ Update Art Cache."
    private let unreadable = "The unreadable-files list clears at the next scan."
    private let soundAnalysis = "Update Sound Analysis measures the new tracks."
    private let ejectDevice = "Eject the device before unplugging."

    private func podBox(engine: String? = nil, layout: Int? = 5) -> DeviceFirmware {
        DeviceFirmware(flavour: .podBox, layout: layout,
                       build: RockboxBuildInfo(target: "ipodvideo", version: "-261108"),
                       config: PodBoxConfig(defaultConfig: nil, config: engine.map { "playlist engine: \($0)\n" }))
    }

    func testAudioOnly() {
        XCTAssertEqual(PodBoxNextSteps.after(.audio, firmware: podBox()), [update])
    }

    func testPlaylistsOnly() {
        XCTAssertEqual(PodBoxNextSteps.after(.playlists, firmware: podBox()), [update])
    }

    func testAudioAndCovers() {
        XCTAssertEqual(PodBoxNextSteps.after([.audio, .covers], firmware: podBox()), [update, artCache])
    }

    func testCoversOnlyStartsWithEject() {
        XCTAssertEqual(PodBoxNextSteps.after(.covers, firmware: podBox()), ["Eject the iPod.", artCache])
        XCTAssertEqual(PodBoxNextSteps.after(.pictures, firmware: podBox()), ["Eject the iPod.", artCache])
    }

    func testCleanupOnly() {
        XCTAssertEqual(PodBoxNextSteps.after(.cleanup, firmware: podBox()), [unreadable])
    }

    func testEverythingInOrder() {
        XCTAssertEqual(PodBoxNextSteps.after([.cleanup, .lyrics, .pictures, .audio, .playlists, .covers],
                                             firmware: podBox(engine: "on")),
                       [update, artCache, unreadable, soundAnalysis])
    }

    func testLyricsOnlyIsEmpty() {
        XCTAssertEqual(PodBoxNextSteps.after(.lyrics, firmware: podBox()), [])
    }

    func testEngineOnAddsSoundAnalysis() {
        XCTAssertEqual(PodBoxNextSteps.after(.audio, firmware: podBox(engine: "on")), [update, soundAnalysis])
        XCTAssertEqual(PodBoxNextSteps.after(.audio, firmware: podBox(engine: "off")), [update])
        // Playlists alone add no tracks to measure.
        XCTAssertEqual(PodBoxNextSteps.after(.playlists, firmware: podBox(engine: "on")), [update])
    }

    func testNotBootedPodBoxGetsPodBoxLines() {
        XCTAssertEqual(PodBoxNextSteps.after(.audio, firmware: podBox(layout: nil)), [update])
    }

    func testStockRockboxGetsOneLine() {
        let stock = DeviceFirmware(flavour: .stockRockbox, layout: nil,
                                   build: RockboxBuildInfo(target: "ipodvideo", version: "v4.0"))
        XCTAssertEqual(PodBoxNextSteps.after([.audio, .covers], firmware: stock), [ejectDevice])
        let unknown = DeviceFirmware(flavour: .unknownRockbox, layout: nil, build: nil)
        XCTAssertEqual(PodBoxNextSteps.after(.cleanup, firmware: unknown), [ejectDevice])
    }

    func testNoFirmwareGetsOneLine() {
        XCTAssertEqual(PodBoxNextSteps.after(.audio, firmware: nil), [ejectDevice])
    }

    func testNoChangesIsEmpty() {
        XCTAssertEqual(PodBoxNextSteps.after([], firmware: podBox()), [])
        XCTAssertEqual(PodBoxNextSteps.after([], firmware: nil), [])
    }

    func testNoLineContainsAnEmDash() {
        let all: DeviceWriteChanges = [.audio, .covers, .pictures, .lyrics, .playlists, .cleanup, .knownArtists]
        let lines = PodBoxNextSteps.after(all, firmware: podBox(engine: "on"))
            + PodBoxNextSteps.after(.covers, firmware: podBox())
            + PodBoxNextSteps.after(.audio, firmware: nil)
        XCTAssertEqual(lines.count, 7) // every distinct line, "Eject the iPod." included
        for line in lines {
            XCTAssertFalse(line.contains("\u{2014}"), line)
        }
    }

    func testIsDoneNeedsMoreThanAMinute() {
        let write = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: write, playerFileModified: write))
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: write, playerFileModified: write.addingTimeInterval(60)))
        XCTAssertTrue(PodBoxNextSteps.isDone(lastWrite: write, playerFileModified: write.addingTimeInterval(61)))
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: write, playerFileModified: write.addingTimeInterval(-600)))
    }

    func testIsDoneFalseWhenEitherMissing() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: nil, playerFileModified: date))
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: date, playerFileModified: nil))
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: nil, playerFileModified: nil))
    }
}
