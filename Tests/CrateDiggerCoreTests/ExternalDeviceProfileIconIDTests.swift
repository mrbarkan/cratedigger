#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Adding `iconID` to `ExternalDeviceProfile` must be a *non-destructive* schema
/// change: profiles saved before the field existed (JSON with no `iconID` key)
/// must still decode — otherwise the `try? … ?? []` load path would silently
/// wipe every saved device profile on first launch after the update.
final class ExternalDeviceProfileIconIDTests: XCTestCase {

    func testLegacyJSONWithoutIconIDDecodesToNil() throws {
        // A profile as it was serialized *before* iconID existed.
        let legacy = """
        {
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "name": "Old iPod",
          "kind": "rockbox_ipod",
          "musicDirectorySubpath": "Music",
          "transferSettings": {
            "mode": "convert_during_transfer",
            "outputFormat": "mp3",
            "bitrateKbps": 192,
            "sampleRateHz": 44100,
            "artworkMaxDimension": 600,
            "deviceProfile": "generic",
            "folderStructureMode": "metadata_template",
            "templateConfig": { "preset": "custom", "tokenOrder": ["album_artist","album","disabled","disabled","disabled"] }
          },
          "createdAt": 0,
          "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ExternalDeviceProfile.self, from: legacy)
        XCTAssertNil(decoded.iconID, "Legacy profiles must decode with a nil iconID, not throw")
        XCTAssertEqual(decoded.name, "Old iPod")
        XCTAssertEqual(decoded.kind, .rockboxIPod)
    }

    func testIconIDRoundTrips() throws {
        var profile = ExternalDeviceProfile(name: "My iPod", kind: .rockboxIPod)
        profile.iconID = "classic.black"

        let data = try JSONEncoder().encode(profile)
        let back = try JSONDecoder().decode(ExternalDeviceProfile.self, from: data)
        XCTAssertEqual(back.iconID, "classic.black")
    }
}
#endif
