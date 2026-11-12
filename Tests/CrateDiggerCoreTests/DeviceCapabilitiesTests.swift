import XCTest
@testable import CrateDiggerCore

/// One test per row of the spec's capability table.
final class DeviceCapabilitiesTests: XCTestCase {
    private func firmware(flavour: RockboxFlavour = .podBox, layout: Int? = 5,
                          prefix: String? = "/<HDD0>", config: String? = nil,
                          scrobblerLog: Bool = false) -> DeviceFirmware {
        DeviceFirmware(flavour: flavour, layout: layout,
                       build: RockboxBuildInfo(target: "ipodvideo", version: "-261108"),
                       config: PodBoxConfig(defaultConfig: nil, config: config),
                       playerPathPrefix: prefix, scrobblerLogPresent: scrobblerLog)
    }

    func testFATOrExFATVolumeGetsAppleDoubleSweep() {
        XCTAssertEqual(DeviceCapabilities(firmware: nil, fileSystem: "msdos"), [.appleDoubleSweep])
        XCTAssertEqual(DeviceCapabilities(firmware: nil, fileSystem: "exfat"), [.appleDoubleSweep])
        XCTAssertEqual(DeviceCapabilities(firmware: nil, fileSystem: "apfs"), [])
        XCTAssertEqual(DeviceCapabilities(firmware: nil, fileSystem: nil), [])
    }

    func testRockboxFolderGivesCoverSidecarAndScrobblerWhenLogExists() {
        let stock = DeviceCapabilities(firmware: firmware(flavour: .stockRockbox, layout: nil), fileSystem: "hfs")
        XCTAssertEqual(stock, [.coverSidecar])

        let withLog = DeviceCapabilities(
            firmware: firmware(flavour: .unknownRockbox, layout: nil, scrobblerLog: true), fileSystem: "msdos")
        XCTAssertEqual(withLog, [.appleDoubleSweep, .coverSidecar, .scrobblerLogImport])
    }

    func testPodBoxLayoutFiveGetsEverything() {
        let caps = DeviceCapabilities(firmware: firmware(), fileSystem: "msdos")
        XCTAssertEqual(caps, [.appleDoubleSweep, .coverSidecar, .centralPeopleArtwork,
                              .lyricsSidecar, .playbackLogImport, .playlistCatalog])
    }

    func testPodBoxNeverBootedGetsFileFeaturesOnly() {
        let notBooted = firmware(layout: nil, prefix: nil)
        let caps = DeviceCapabilities(firmware: notBooted, fileSystem: "msdos")
        XCTAssertEqual(caps, [.appleDoubleSweep, .coverSidecar, .centralPeopleArtwork])
        XCTAssertEqual(notBooted.layoutNotice, "Start the iPod once so PodBox can finish setting up")
        XCTAssertNil(firmware().layoutNotice)
    }

    func testLayoutSixKeepsFileFeaturesLosesReadBack() {
        let newer = firmware(layout: 6)
        let caps = DeviceCapabilities(firmware: newer, fileSystem: "msdos")
        XCTAssertTrue(caps.contains(.coverSidecar))
        XCTAssertTrue(caps.contains(.centralPeopleArtwork))
        XCTAssertFalse(caps.contains(.playbackLogImport))
        XCTAssertFalse(caps.contains(.lyricsSidecar))
        XCTAssertEqual(newer.layoutNotice,
                       "This iPod runs a newer PodBox library layout (6) than CrateDigger knows (5)")
    }

    func testNoPlaylistCapabilityWithoutPrefix() {
        let caps = DeviceCapabilities(firmware: firmware(prefix: nil), fileSystem: "msdos")
        XCTAssertFalse(caps.contains(.playlistCatalog))
        XCTAssertTrue(caps.contains(.playbackLogImport))
    }

    func testPlaylistFolderInsideRockboxGivesNoCapability() {
        for folder in ["/.rockbox/playlists", "/.ROCKBOX./lists", "/iPod_Control/Lists", "/../Lists", "//x"] {
            let caps = DeviceCapabilities(
                firmware: firmware(config: "playlist catalog directory: \(folder)\n"), fileSystem: "msdos")
            XCTAssertFalse(caps.contains(.playlistCatalog), folder)
        }
        let fine = DeviceCapabilities(
            firmware: firmware(config: "playlist catalog directory: /My Lists\n"), fileSystem: "msdos")
        XCTAssertTrue(fine.contains(.playlistCatalog))
    }
}
