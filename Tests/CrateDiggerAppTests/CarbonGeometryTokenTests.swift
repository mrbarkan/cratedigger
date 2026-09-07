#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The key corner radius is its own dial: the flat keys and the header
/// buttons used to be hard-wired to 6 while every other surface had a token.
final class CarbonGeometryTokenTests: XCTestCase {
    func testKeyCornerRadiusShipsAtSixAndIsEditable() {
        XCTAssertEqual(CarbonGeometry.standard.keyCornerRadius, 6)
        XCTAssertTrue(ThemeTokenCatalog.allGeometryTokens.contains { $0.key == "keyCornerRadius" },
                      "keyCornerRadius has no dial in the theme editor")
    }

    func testKeyCornerRadiusIsClampedToAKeySizedRange() {
        let square = CarbonGeometry(definition: ThemeDefinition(
            id: "t", name: "T", baseAppearance: .dark, geometry: ["keyCornerRadius": 0]
        ))
        XCTAssertEqual(square.keyCornerRadius, 0)

        let capsule = CarbonGeometry(definition: ThemeDefinition(
            id: "t", name: "T", baseAppearance: .dark, geometry: ["keyCornerRadius": 99]
        ))
        XCTAssertEqual(capsule.keyCornerRadius, CarbonGeometry.Bounds.keyCornerRadius.upperBound)
    }
}
#endif
