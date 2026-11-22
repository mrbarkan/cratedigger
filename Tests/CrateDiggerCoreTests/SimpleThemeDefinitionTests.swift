import XCTest
@testable import CrateDiggerCore

final class SimpleThemeDefinitionTests: XCTestCase {
    private func recipe() -> SimpleThemeRecipe {
        SimpleThemeRecipe(
            palette: ["#112233", "#445566", "#778899"],
            pins: [.accent: 2],
            assignment: [.frame: 0, .panels: 1, .glass: nil],
            contrast: .high,
            recipe: 3
        )
    }

    private func theme(_ simple: SimpleThemeRecipe?) -> ThemeDefinition {
        ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, simple: simple)
    }

    private func decode(simpleJSON: String) throws -> ThemeDefinition {
        let json = "{\"id\":\"t\",\"name\":\"T\",\"baseAppearance\":\"dark\",\"simple\":\(simpleJSON)}"
        return try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
    }

    func testRoundTripPreservesBlock() throws {
        let def = theme(recipe())
        let data = try JSONEncoder().encode(def)
        let back = try JSONDecoder().decode(ThemeDefinition.self, from: data)
        XCTAssertEqual(back.simple, def.simple)
        XCTAssertTrue(back.isSimple)
    }

    func testNilBlockIsOmittedFromJSON() throws {
        let data = try JSONEncoder().encode(theme(nil))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("simple"))
    }

    func testOldFileWithoutBlockDecodes() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/CrateDiggerApp/Resources/Themes/Carbon.cdtheme/theme.json")
        let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
        XCTAssertNil(def.simple)
        XCTAssertFalse(def.isSimple)
    }

    func testMinimizedKeepsBlock() {
        let parent = ThemeDefinition(id: "p", name: "P", baseAppearance: .dark, colors: ["ink": "#FFFFFF"])
        var def = theme(recipe())
        def.inherits = "p"
        def.colors = ["ink": "#00FF00"]
        XCTAssertEqual(ThemeAuthoringService.minimized(def, against: parent).simple, def.simple)
    }

    func testMalformedBlockIsSanitized() throws {
        XCTAssertNil(try decode(simpleJSON: "{\"palette\":[\"#112233\"]}").simple)
        let seven = (0..<7).map { String(format: "\"#0000%02X\"", $0 + 16) }.joined(separator: ",")
        XCTAssertEqual(try decode(simpleJSON: "{\"palette\":[\(seven)]}").simple?.palette.count, 6)
        let pinned = try decode(simpleJSON: "{\"palette\":[\"#112233\",\"#445566\"],\"pins\":{\"accent\":9,\"frame\":1},\"assignment\":{\"text\":7,\"panels\":0}}").simple
        XCTAssertEqual(pinned?.pins, [.frame: 1])
        XCTAssertEqual(pinned?.assignment.count, 1)
        let bad = try decode(simpleJSON: "{\"palette\":[\"#zz\",\"#112233\",\"#445566\"]}").simple
        XCTAssertEqual(bad?.palette, ["#112233", "#445566"])
    }

    func testStructurallyWrongBlockDecodesAsNil() throws {
        XCTAssertNil(try decode(simpleJSON: "\"nope\"").simple)
        XCTAssertNil(try decode(simpleJSON: "[1,2]").simple)
        XCTAssertNil(try decode(simpleJSON: "{\"palette\":\"red\"}").simple)
    }

    func testNullAssignmentRoundTrips() throws {
        let data = try JSONEncoder().encode(theme(recipe()))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"glass\":null"))
        let back = try JSONDecoder().decode(ThemeDefinition.self, from: data)
        let entry = try XCTUnwrap(back.simple?.assignment[.glass])
        XCTAssertNil(entry)
        XCTAssertEqual(back.simple?.assignment[.frame], .some(0))
    }

    func testLabelsAndOrder() {
        XCTAssertEqual(ThemeJob.glass.label, "Screen Glass")
        XCTAssertEqual(ThemeJob.allCases.map(\.rawValue), ["frame", "panels", "text", "accent", "glass", "screenText"])
    }
}
