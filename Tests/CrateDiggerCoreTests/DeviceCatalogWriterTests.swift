#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// A whole-volume scan that finishes after a transfer patched the catalog
/// must not put the older picture back.
final class DeviceCatalogWriterTests: XCTestCase {
    func testScanSaveLandsWhenNothingChangedMeanwhile() throws {
        try withTemporaryDirectory(prefix: "catalog-writer") { dir in
            let writer = DeviceCatalogWriter(store: DeviceCatalogStore(directory: dir))
            let token = writer.scanToken(key: "IPOD")

            XCTAssertTrue(writer.saveScan([track("One")], key: "IPOD", token: token))
            XCTAssertEqual(writer.load(key: "IPOD")?.map(\.track.title), ["One"])
        }
    }

    func testScanSaveAfterAPatchIsSkipped() throws {
        try withTemporaryDirectory(prefix: "catalog-writer") { dir in
            let writer = DeviceCatalogWriter(store: DeviceCatalogStore(directory: dir))
            XCTAssertTrue(writer.saveScan([track("One")], key: "IPOD", token: writer.scanToken(key: "IPOD")))

            // A browse walk starts, a transfer writes "Two" and patches, the walk ends.
            let token = writer.scanToken(key: "IPOD")
            let patched = writer.patch(key: "IPOD", adding: [track("Two")], removingPaths: [])
            let saved = writer.saveScan([track("One")], key: "IPOD", token: token)

            XCTAssertEqual(patched?.map(\.track.title), ["One", "Two"])
            XCTAssertFalse(saved)
            XCTAssertEqual(writer.load(key: "IPOD")?.map(\.track.title), ["One", "Two"])
        }
    }

    func testRemoveRefusesAScanAlreadyUnderWay() throws {
        try withTemporaryDirectory(prefix: "catalog-writer") { dir in
            let writer = DeviceCatalogWriter(store: DeviceCatalogStore(directory: dir))
            let early = writer.scanToken(key: "IPOD")

            writer.remove(key: "IPOD")

            XCTAssertFalse(writer.saveScan([track("Stale")], key: "IPOD", token: early))
            XCTAssertNil(writer.load(key: "IPOD"))
            // A walk started after the removal (RESCAN) saves.
            XCTAssertTrue(writer.saveScan([track("Fresh")], key: "IPOD", token: writer.scanToken(key: "IPOD")))
        }
    }

    func testPatchWithoutACatalogReturnsNil() throws {
        try withTemporaryDirectory(prefix: "catalog-writer") { dir in
            let writer = DeviceCatalogWriter(store: DeviceCatalogStore(directory: dir))

            XCTAssertNil(writer.patch(key: "IPOD", adding: [track("One")], removingPaths: []))
            XCTAssertNil(writer.load(key: "IPOD"))
        }
    }

    func testKeysAreIndependent() throws {
        try withTemporaryDirectory(prefix: "catalog-writer") { dir in
            let writer = DeviceCatalogWriter(store: DeviceCatalogStore(directory: dir))
            let token = writer.scanToken(key: "STICK")

            writer.remove(key: "IPOD")

            XCTAssertTrue(writer.saveScan([track("One")], key: "STICK", token: token))
        }
    }

    private func track(_ title: String) -> LoadedTrack {
        let audio = AudioTrack(fileURL: URL(fileURLWithPath: "/Volumes/IPOD/Music/\(title).mp3"),
                               title: title, artist: "Artist", album: "Album")
        return LoadedTrack(track: audio, metadata: ConversionMetadata(title: title))
    }
}

/// Which mounted volume a profile's root lies on.
final class MountedDeviceContainingTests: XCTestCase {
    private let ipod = MountedDevice(name: "IPOD", volumeURL: URL(fileURLWithPath: "/Volumes/IPOD"))
    private let ipod2 = MountedDevice(name: "IPOD 2", volumeURL: URL(fileURLWithPath: "/Volumes/IPOD 2"))
    private let card = MountedDevice(name: "CARD", volumeURL: URL(fileURLWithPath: "/Volumes/CARD"))

    func testTheVolumeItself() {
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD"), in: [card, ipod]), ipod)
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD/"), in: [card, ipod]), ipod)
    }

    func testAFolderOnTheVolume() {
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD/Music"), in: [card, ipod]), ipod)
    }

    func testASharedNamePrefixIsAnotherVolume() {
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD 2/Music"), in: [ipod, ipod2]), ipod2)
        XCTAssertNil(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD 2"), in: [ipod]))
    }

    func testCaseIsIgnored() {
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/volumes/ipod/MUSIC"), in: [ipod]), ipod)
    }

    func testNothingMountedThere() {
        XCTAssertNil(MountedDevice.containing(URL(fileURLWithPath: "/Users/me/Music"), in: [ipod, card]))
        XCTAssertNil(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD"), in: []))
    }

    func testTheDeepestVolumeWins() {
        let nested = MountedDevice(name: "INNER", volumeURL: URL(fileURLWithPath: "/Volumes/IPOD/Inner"))
        XCTAssertEqual(MountedDevice.containing(URL(fileURLWithPath: "/Volumes/IPOD/Inner/Music"), in: [ipod, nested]), nested)
    }
}
#endif
