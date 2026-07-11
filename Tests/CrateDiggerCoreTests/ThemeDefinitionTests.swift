#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ThemeDefinitionTests: XCTestCase {
    func testDecodesMinimalTheme() throws {
        let json = """
        {
          "id": "sunset-vinyl",
          "name": "Sunset Vinyl",
          "baseAppearance": "dark",
          "inherits": "carbon",
          "colors": { "orange": "#FF6236", "chassis": "#171C22FF" }
        }
        """

        let definition = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(definition.id, "sunset-vinyl")
        XCTAssertEqual(definition.name, "Sunset Vinyl")
        XCTAssertEqual(definition.baseAppearance, .dark)
        XCTAssertEqual(definition.inherits, "carbon")
        XCTAssertEqual(definition.colors?["orange"], "#FF6236")
        XCTAssertNil(definition.author)
        XCTAssertNil(definition.fonts)
        XCTAssertNil(definition.geometry)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = """
        {
          "id": "future-proof",
          "name": "Future Proof",
          "baseAppearance": "light",
          "someFieldFromANewerCrateDigger": 42
        }
        """

        let definition = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.id, "future-proof")
    }

    func testShadowAndGeometryDecode() throws {
        let json = """
        {
          "id": "custom",
          "name": "Custom",
          "baseAppearance": "dark",
          "shadows": { "shadow1": { "color": "#000000", "opacity": 0.5, "radius": 12, "x": 0, "y": 3 } },
          "geometry": { "chassisCornerRadius": 4, "playButtonSize": 90 }
        }
        """

        let definition = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.shadows?["shadow1"]?.radius, 12)
        XCTAssertEqual(definition.shadows?["shadow1"]?.opacity, 0.5)
        XCTAssertEqual(definition.geometry?["playButtonSize"], 90)
    }

    func testMissingRequiredFieldFailsToDecode() {
        let json = """
        { "id": "no-appearance", "name": "No Appearance" }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8)))
    }
}
#endif
