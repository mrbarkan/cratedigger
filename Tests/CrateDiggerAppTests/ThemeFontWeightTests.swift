#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The weight ladder a theme can name, and how a request that lands between
/// two named faces is served.
final class ThemeFontWeightTests: XCTestCase {

    // MARK: - Bucketing SwiftUI's nine weights onto the five a theme names

    func testLightWeightsShareTheLightSlot() {
        XCTAssertEqual(Font.Weight.ultraLight.themeWeight, .light)
        XCTAssertEqual(Font.Weight.thin.themeWeight, .light)
        XCTAssertEqual(Font.Weight.light.themeWeight, .light)
    }

    func testHeavierThanBoldReadsAsBold() {
        XCTAssertEqual(Font.Weight.bold.themeWeight, .bold)
        XCTAssertEqual(Font.Weight.heavy.themeWeight, .bold)
        XCTAssertEqual(Font.Weight.black.themeWeight, .bold)
    }

    func testMiddleWeightsMapStraightThrough() {
        XCTAssertEqual(Font.Weight.regular.themeWeight, .regular)
        XCTAssertEqual(Font.Weight.medium.themeWeight, .medium)
        XCTAssertEqual(Font.Weight.semibold.themeWeight, .semibold)
    }

    // MARK: - Resolution

    func testNamedLightFaceIsUsed() {
        let font = ThemeFont(regular: "Base", light: "Thin", bold: "Heavy")
        XCTAssertEqual(font.resolvedFace(for: .light), "Thin")
        XCTAssertEqual(font.face(for: .light), "Thin")
    }

    /// The one direction that must never happen: a missing light falling
    /// through to a heavier face would invert the hierarchy the caller asked
    /// for — a "thin" headline coming out bold.
    func testMissingLightFallsUpToRegularNeverToBold() {
        let font = ThemeFont(regular: "Base", medium: "Med", semibold: "Semi", bold: "Heavy")
        XCTAssertEqual(font.resolvedFace(for: .light), "Base")
        XCTAssertNil(font.face(for: .light))
    }

    func testMissingMiddleWeightsStillPreferAHeavierNamedFace() {
        let font = ThemeFont(regular: "Base", bold: "Heavy")
        XCTAssertEqual(font.resolvedFace(for: .semibold), "Heavy")
        XCTAssertEqual(font.resolvedFace(for: .medium), "Heavy")
    }

    // MARK: - Editing

    func testSetFaceNamesAndClearsASlot() {
        var font = ThemeFont(regular: "Base")
        font.setFace("Thin", for: .light)
        XCTAssertEqual(font.light, "Thin")

        font.setFace(nil, for: .light)
        XCTAssertNil(font.light)
    }

    /// Clearing the base would leave the role with nothing to fall back to.
    func testClearingRegularIsIgnored() {
        var font = ThemeFont(regular: "Base")
        font.setFace(nil, for: .regular)
        XCTAssertEqual(font.regular, "Base")

        font.setFace("Other", for: .regular)
        XCTAssertEqual(font.regular, "Other")
    }

    // MARK: - Serialization

    func testLightSurvivesARoundTrip() throws {
        let font = ThemeFont(regular: "Base", light: "Thin")
        let decoded = try JSONDecoder().decode(ThemeFont.self, from: JSONEncoder().encode(font))
        XCTAssertEqual(decoded, font)
    }

    /// A role naming only its base still writes the `"sans": "Helvetica"`
    /// shorthand a hand-authored theme uses.
    func testSingleFaceStillEncodesAsABareString() throws {
        let data = try JSONEncoder().encode(ThemeFont(regular: "Helvetica"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Helvetica\"")
    }
}
#endif
