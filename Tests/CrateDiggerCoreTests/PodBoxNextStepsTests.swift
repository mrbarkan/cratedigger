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

    // MARK: The stamp recorded at write time

    func testRecordedStampClearsOnAnyChangeWhateverTheClock() {
        // An iPod whose clock was never set stamps 2000, long before our write.
        let unsetClock = Date(timeIntervalSince1970: 946_684_800)
        let write = Date(timeIntervalSince1970: 1_800_000_000)
        let mark = PodBoxNextSteps.ArtCacheMark(wroteAt: write, stampAtWrite: unsetClock)
        XCTAssertFalse(PodBoxNextSteps.isDone(mark, stampNow: unsetClock), "not rebuilt yet")
        XCTAssertTrue(PodBoxNextSteps.isDone(mark, stampNow: unsetClock.addingTimeInterval(2)),
                      "rebuilt: the stamp moved, even though it is still decades before the Mac's write")
        XCTAssertTrue(PodBoxNextSteps.isDone(mark, stampNow: unsetClock.addingTimeInterval(-60)), "any change")
        XCTAssertFalse(PodBoxNextSteps.isDone(mark, stampNow: nil), "no stamp: not rebuilt")
        // The old rule would never have cleared it.
        XCTAssertFalse(PodBoxNextSteps.isDone(lastWrite: write, playerFileModified: unsetClock.addingTimeInterval(2)))
    }

    func testStampThatAppearsAfterTheWriteClears() {
        let mark = PodBoxNextSteps.ArtCacheMark(wroteAt: Date(), stampAtWrite: nil)
        XCTAssertFalse(PodBoxNextSteps.isDone(mark, stampNow: nil))
        XCTAssertTrue(PodBoxNextSteps.isDone(mark, stampNow: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(PodBoxNextSteps.isDone(nil, stampNow: Date()))
    }

    func testMarkWithoutARecordedStampKeepsTheDateRule() {
        let write = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = PodBoxNextSteps.ArtCacheMark(wroteAt: write, stampAtWrite: nil, recordedStamp: false)
        XCTAssertFalse(PodBoxNextSteps.isDone(legacy, stampNow: write.addingTimeInterval(30)))
        XCTAssertTrue(PodBoxNextSteps.isDone(legacy, stampNow: write.addingTimeInterval(61)))
    }

    func testPreferencesKeepTheMarkAndReadTheOldDate() throws {
        let suite = "PodBoxNextStepsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PreferencesStore(defaults: defaults)
        let id = UUID()
        XCTAssertNil(prefs.podBoxArtCacheMark(profileID: id))

        let old = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(old, forKey: PreferencesStore.podBoxLastArtWriteKey(id))
        XCTAssertEqual(prefs.podBoxArtCacheMark(profileID: id),
                       PodBoxNextSteps.ArtCacheMark(wroteAt: old, stampAtWrite: nil, recordedStamp: false))

        let mark = PodBoxNextSteps.ArtCacheMark(wroteAt: old, stampAtWrite: Date(timeIntervalSince1970: 946_684_800))
        prefs.setPodBoxArtCacheMark(mark, profileID: id)
        XCTAssertEqual(prefs.podBoxArtCacheMark(profileID: id), mark)
        XCTAssertNil(defaults.object(forKey: PreferencesStore.podBoxLastArtWriteKey(id)), "the old key is dropped")

        prefs.setPodBoxArtCacheMark(nil, profileID: id)
        XCTAssertNil(prefs.podBoxArtCacheMark(profileID: id))
    }
}
