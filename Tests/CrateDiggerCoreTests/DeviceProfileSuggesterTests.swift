#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class DeviceProfileSuggesterTests: XCTestCase {
    func testRockboxDetectedFromDotRockboxFolder() {
        let (kind, music) = DeviceProfileSuggester.suggest(
            fromTopLevelEntries: [".rockbox", "iPod_Control", "Music", "Podcasts"]
        )
        XCTAssertEqual(kind, .rockboxIPod)
        XCTAssertEqual(music, "Music")
    }

    func testMusicFolderCasingPreserved() {
        let (_, music) = DeviceProfileSuggester.suggest(
            fromTopLevelEntries: [".rockbox", "MUSIC"]
        )
        XCTAssertEqual(music, "MUSIC")
    }

    func testGenericVolumeWithoutMusicFolderDefaultsToMusic() {
        let (kind, music) = DeviceProfileSuggester.suggest(
            fromTopLevelEntries: ["DCIM", "Documents"]
        )
        XCTAssertEqual(kind, .genericExternalStorage)
        XCTAssertEqual(music, "Music")
    }

    func testStockIPodWithoutRockboxIsGeneric() {
        // iPod_Control alone (no .rockbox) isn't a Rockbox device.
        let (kind, _) = DeviceProfileSuggester.suggest(fromTopLevelEntries: ["iPod_Control"])
        XCTAssertEqual(kind, .genericExternalStorage)
    }
}
#endif
