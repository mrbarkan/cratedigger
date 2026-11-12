import XCTest
@testable import CrateDiggerCore

final class DeviceFirmwareProbeTests: XCTestCase {
    /// The device's own `format.dat`, all 28 bytes (brief, Appendix C).
    private let deviceFormatDat = Data([0x4c, 0x59, 0x4f, 0x54, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
                                       + [UInt8](repeating: 0xff, count: 16))

    // MARK: format.dat

    func testRealFormatDatGivesLayoutFive() {
        XCTAssertEqual(DeviceFirmwareProbe.layoutVersion(formatDat: deviceFormatDat), 5)
    }

    func testChecksumIsNotVerified() {
        // FF FF FF FF is not the CRC of an empty tail; a strict reader would
        // reject the real iPod. Any checksum value must read the same.
        var other = [UInt8](deviceFormatDat)
        other.replaceSubrange(24..<28, with: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(DeviceFirmwareProbe.layoutVersion(formatDat: Data(other)), 5)
    }

    func testShortEmptyAndWrongMagicGiveNil() {
        XCTAssertNil(DeviceFirmwareProbe.layoutVersion(formatDat: Data()))
        XCTAssertNil(DeviceFirmwareProbe.layoutVersion(formatDat: Data([0x4c, 0x59, 0x4f])))
        XCTAssertNil(DeviceFirmwareProbe.layoutVersion(formatDat: deviceFormatDat.prefix(27)))
        var wrong = [UInt8](deviceFormatDat)
        wrong[0] = 0x41 // "AYOT"
        XCTAssertNil(DeviceFirmwareProbe.layoutVersion(formatDat: Data(wrong)))
        XCTAssertNil(DeviceFirmwareProbe.layoutVersion(formatDat: Data("ARTS".utf8) + Data(count: 24)))
    }

    // MARK: rockbox-info.txt

    func testBuildInfoFromDeviceText() {
        let info = DeviceFirmwareProbe.buildInfo(rockboxInfo: FakeIPod.rockboxInfo)
        XCTAssertEqual(info.target, "ipodvideo")
        XCTAssertEqual(info.version, "-261108")
        XCTAssertNil(info.gitHash)
        XCTAssertEqual(info.buildDate, DateComponents(year: 2026, month: 11, day: 8))
        XCTAssertEqual(info.modelName, "iPod Video")
    }

    func testStockVersionForms() {
        let dev = DeviceFirmwareProbe.buildInfo(rockboxInfo: "Target: ipod6g\nVersion: abc1234-250101\n")
        XCTAssertEqual(dev.gitHash, "abc1234")
        XCTAssertEqual(dev.buildDate, DateComponents(year: 2025, month: 1, day: 1))
        XCTAssertEqual(dev.modelName, "iPod Classic")

        let release = DeviceFirmwareProbe.buildInfo(rockboxInfo: "Target: ipodnano2g\nVersion: v4.0\n")
        XCTAssertEqual(release.version, "v4.0")
        XCTAssertNil(release.buildDate)
        XCTAssertEqual(release.modelName, "iPod (ipodnano2g)")

        let unknown = DeviceFirmwareProbe.buildInfo(rockboxInfo: "Version: unknown\n")
        XCTAssertNil(unknown.buildDate)
        XCTAssertNil(unknown.target)
        XCTAssertEqual(unknown.modelName, "iPod")
    }

    func testCRLFAndUnknownKeysTolerated() {
        let text = "Target: ipodvideo\r\nWhatever Key: 12\r\nno separator here\r\nVersion: -261108\r\n"
        let info = DeviceFirmwareProbe.buildInfo(rockboxInfo: text)
        XCTAssertEqual(info.target, "ipodvideo")
        XCTAssertEqual(info.buildDate, DateComponents(year: 2026, month: 11, day: 8))

        let values = DeviceFirmwareProbe.configValues("# comment\r\n\r\nplay log: last.fm\r\nodd line\r\n")
        XCTAssertEqual(values, ["play log": "last.fm"])
    }

    // MARK: config

    func testConfigLayering() {
        let config = PodBoxConfig(defaultConfig: "database artist art: on\nplay log: off\n",
                                  config: "database artist art: off\n")
        XCTAssertFalse(config.artistArt)
        XCTAssertEqual(config.playLogMode, .off)
        XCTAssertEqual(config.value("database album art"), "on") // from the defaults table

        let duplicate = PodBoxConfig(defaultConfig: nil, config: "play log: off\nplay log: last.fm\n")
        XCTAssertEqual(duplicate.playLogMode, .lastFM)
    }

    func testConfigDefaultsWhenKeysAbsent() {
        let config = PodBoxConfig(defaultConfig: nil, config: FakeIPod.config)
        XCTAssertEqual(config.playLogMode, .on)
        XCTAssertEqual(config.playlistDirectory, "Playlists")
        XCTAssertEqual(config.scanPaths, ["/"])
        XCTAssertFalse(config.yearFromFolder)
        XCTAssertTrue(config.artistArt)
        XCTAssertFalse(config.featuredArtists)
        XCTAssertEqual(config.value("skip ipod games"), "on")
        XCTAssertEqual(config.value("playlist engine"), "off")
    }

    // MARK: path prefix

    func testPrefixFromPlaylistLine() {
        let lines = ["\u{FEFF}" + FakeIPod.playlistLine.trimmingCharacters(in: .newlines)]
        XCTAssertEqual(DeviceFirmwareProbe.playerPathPrefix(fromPlayerLines: lines), "/<HDD0>")
    }

    func testPrefixFromLogLine() {
        let lines = FakeIPod.playbackLog.components(separatedBy: "\n")
        XCTAssertEqual(DeviceFirmwareProbe.playerPathPrefix(fromPlayerLines: lines), "/<HDD0>")
    }

    func testPrefixFromPlaylistControlLine() {
        let lines = ["P:6:/<HDD0>/Music/Classics/Beach House/2010 Teen Dream:", "A:0:-1:01 - Zebra.m4a"]
        XCTAssertEqual(DeviceFirmwareProbe.playerPathPrefix(fromPlayerLines: lines), "/<HDD0>")
    }

    func testNoPrefixWhenAbsent() {
        XCTAssertNil(DeviceFirmwareProbe.playerPathPrefix(fromPlayerLines: []))
        XCTAssertNil(DeviceFirmwareProbe.playerPathPrefix(fromPlayerLines: [
            "/Music/a.mp3", "/<hdd0>/Music/a.mp3", "/<HDD>/Music/a.mp3", "/<0>/a.mp3", "# Started Ver. -261108",
        ]))
    }

    // MARK: flavour

    func testFlavourPodBox() throws {
        let iPod = try FakeIPod()
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.flavour, .podBox)
        XCTAssertEqual(firmware.layout, 5)
        XCTAssertEqual(firmware.playerPathPrefix, "/<HDD0>")
        XCTAssertEqual(firmware.playerName, "PodBox")
        XCTAssertEqual(firmware.build?.target, "ipodvideo")
        XCTAssertFalse(firmware.scrobblerLogPresent)
    }

    func testFlavourNotBooted() throws {
        let iPod = try FakeIPod(flavour: .podBoxNotBooted)
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.flavour, .podBox)
        XCTAssertNil(firmware.layout)
        XCTAssertEqual(firmware.summaryLine, "PodBox, not started yet · iPod Video")
    }

    func testFlavourStock() throws {
        let iPod = try FakeIPod(flavour: .stockRockbox)
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.flavour, .stockRockbox)
        XCTAssertEqual(firmware.summaryLine, "Rockbox · iPod Video")
        XCTAssertEqual(DeviceFirmwareProbe.flavour(layout: nil, rockboxEntries: ["rocks", "default-config.cfg",
                                                                                 "trim.config", "docs/settings-help.txt"]),
                       .stockRockbox)
    }

    func testFlavourUnknown() throws {
        let iPod = try FakeIPod(flavour: .unknownRockbox)
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.flavour, .unknownRockbox)
        XCTAssertNil(firmware.build)
        XCTAssertEqual(firmware.summaryLine, "Rockbox · iPod")
        XCTAssertEqual(DeviceFirmwareProbe.flavour(layout: nil, rockboxEntries: ["default-config.cfg", "trim.config"]),
                       .unknownRockbox)
    }

    func testNoRockboxGivesNil() throws {
        let iPod = try FakeIPod(flavour: .noRockbox)
        XCTAssertNil(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        // A file named .rockbox is not the player's folder either.
        try iPod.addFile(".rockbox", Data("x".utf8))
        XCTAssertNil(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
    }

    // MARK: unreadable.txt

    func testAppleDoubleCountFromUnreadableText() {
        let text = """
        /Music/Classics/Beach House/2010 Teen Dream/._01 - Zebra.m4a
        /Music/Classics/Beach House/2010 Teen Dream/02 - Silver Soul.m4a\r
        /Music/Classics/Beach House/2010 Teen Dream/._02 - Silver Soul.m4a\r
        """
        XCTAssertEqual(DeviceFirmwareProbe.appleDoubleCount(unreadableText: text), 2)
        XCTAssertEqual(DeviceFirmwareProbe.appleDoubleCount(unreadableText: "/Music/._Folder/a.m4a\n"), 0)
    }

    // MARK: whole probe

    func testProbeOfFakeIPodSummaryLine() throws {
        let iPod = try FakeIPod()
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.summaryLine, "PodBox · iPod Video · build 8 Nov 2026 · library layout 5")
    }

    func testProbeCountsAppleDoublesAndSeesScrobblerLog() throws {
        let iPod = try FakeIPod()
        try iPod.addFile(".rockbox/library/cache/unreadable.txt",
                         Data("/Music/A/._01.m4a\n/Music/A/._02.m4a\n/Music/A/03.m4a\n".utf8))
        try iPod.addFile(".scrobbler.log", Data("#AUDIOSCROBBLER/1.1\n".utf8))
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.unreadableAppleDoubleCount, 2)
        XCTAssertTrue(firmware.scrobblerLogPresent)
    }

    func testPrefixIgnoresAppleDoubleTwinOfPlaylist() throws {
        let iPod = try FakeIPod()
        try iPod.addFile(".rockbox/library/user/playback.log", Data("# Started\n".utf8))
        try iPod.addFile("Playlists/._Pl.m3u8", FakeIPod.appleDoubleBytes())
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.playerPathPrefix, "/<HDD0>")
    }

    func testProbeLeavesPlayerStateUntouched() throws {
        let iPod = try FakeIPod()
        try iPod.addFile(".rockbox/.playlist_control", Data("P:6:/<HDD0>/Music/A:\n".utf8))
        let before = try iPod.manifest()
        _ = DeviceFirmwareProbe.probe(volumeRoot: iPod.root)
        iPod.assertPlayerStateUntouched(since: before)
    }

    func testGarbageFilesNeverThrow() throws {
        let iPod = try FakeIPod()
        var garbage = [UInt8]()
        var seed: UInt32 = 7
        for _ in 0..<4096 {
            seed = seed &* 1_103_515_245 &+ 12345
            garbage.append(UInt8(truncatingIfNeeded: seed >> 16))
        }
        try iPod.addFile(".rockbox/rockbox-info.txt", Data(garbage))
        try iPod.addFile(".rockbox/library/format.dat", Data([0x4c, 0x59, 0x4f]))
        try iPod.addFile(".rockbox/config.cfg", Data("play log: off\r\n\r\n".utf8) + Data(garbage))
        try iPod.addFile(".rockbox/library/user/player_name.txt", Data(garbage))
        try iPod.addFile(".rockbox/library/cache/unreadable.txt", Data(garbage))
        try iPod.addFile(".rockbox/library/user/playback.log", Data(garbage))
        try iPod.addFile("Playlists/Pl.m3u8", Data(garbage))

        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertNil(firmware.layout)
        XCTAssertNil(firmware.playerPathPrefix)
        XCTAssertEqual(firmware.config.playLogMode, .off)
        XCTAssertEqual(firmware.flavour, .podBox) // not booted: the setup files are all there
    }

    func testFifoInPlaceOfConfigDoesNotHang() throws {
        let iPod = try FakeIPod()
        let fifo = iPod.root.appendingPathComponent(".rockbox/config.cfg")
        try FileManager.default.removeItem(at: fifo)
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.layout, 5)
    }

    func testOversizeConfigIsCapped() throws {
        let iPod = try FakeIPod()
        var text = "play log: off\n"
        let filler = String(repeating: "# filler line for a config that is far too large\n", count: 110_000)
        text += filler // about 5.5 MB
        text += "database artist art: off\n"
        try iPod.addFile(".rockbox/config.cfg", Data(text.utf8))

        let firmware = try XCTUnwrap(DeviceFirmwareProbe.probe(volumeRoot: iPod.root))
        XCTAssertEqual(firmware.config.playLogMode, .off)   // inside the first 64 KB
        XCTAssertTrue(firmware.config.artistArt)            // past the cap: never read
    }
}
