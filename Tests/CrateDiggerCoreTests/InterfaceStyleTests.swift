import XCTest
@testable import CrateDiggerCore

final class InterfaceStyleTests: XCTestCase {
    func testAbsentStyleIsRealHardwareAndIsNotEncoded() throws {
        let json = ##"{"id":"t","name":"T","baseAppearance":"dark"}"##
        let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertNil(def.style)
        XCTAssertEqual(def.resolvedStyle, .hardware)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(def)) as? [String: Any]
        XCTAssertFalse(try XCTUnwrap(object).keys.contains("style"))
    }

    func testUnknownStyleReadsAsRealHardwareAndKeepsTheTheme() throws {
        let json = ##"{"id":"t","name":"T","baseAppearance":"dark","style":"neon","colors":{"ink":"#FFFFFF"}}"##
        let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertNil(def.style)
        XCTAssertEqual(def.resolvedStyle, .hardware)
        XCTAssertEqual(def.colors?["ink"], "#FFFFFF")
    }

    func testMalformedStyleReadsAsRealHardwareAndKeepsTheTheme() throws {
        let json = ##"{"id":"t","name":"T","baseAppearance":"dark","style":{"a":1},"colors":{"ink":"#FFFFFF"}}"##
        let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertNil(def.style)
        XCTAssertEqual(def.colors?["ink"], "#FFFFFF")
    }

    func testRawValuesAndStyleRoundTrips() throws {
        XCTAssertEqual(InterfaceStyle.allCases.map(\.rawValue), ["hardware", "flatHardware", "softBlocks", "sticker"])
        XCTAssertEqual(InterfaceStyle.allCases.map(\.displayName),
                       ["Real Hardware", "Flat Hardware", "Soft Blocks", "Sticker"])
        for style in InterfaceStyle.allCases {
            let def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, style: style)
            let data = try JSONEncoder().encode(def)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(style.rawValue)\""))
            XCTAssertEqual(try JSONDecoder().decode(ThemeDefinition.self, from: data).style, style)
        }
    }

    func testChildInheritsParentStyleUnlessItSetsOne() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerInterfaceStyleTests") { directory in
            func write(_ name: String, _ json: String) throws {
                try Data(json.utf8).write(to: directory.appendingPathComponent("\(name).json"))
            }
            try write("parent", ##"{"id":"parent","name":"P","baseAppearance":"dark","style":"flatHardware"}"##)
            try write("plain", ##"{"id":"plain","name":"C","baseAppearance":"dark","inherits":"parent"}"##)
            try write("own", ##"{"id":"own","name":"O","baseAppearance":"dark","inherits":"parent","style":"sticker"}"##)
            let loader = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory)
            let byID = Dictionary(uniqueKeysWithValues: loader.discoverThemes().themes.map { ($0.id, $0.definition) })
            XCTAssertEqual(byID["parent"]?.style, .flatHardware)
            XCTAssertEqual(byID["plain"]?.style, .flatHardware)
            XCTAssertEqual(byID["own"]?.style, .sticker)
        }
    }

    func testSettingRealOnAnInheritingThemeIsExplicit() {
        let child = ThemeDefinition(id: "c", name: "C", baseAppearance: .dark, inherits: "llama-97")
        XCTAssertEqual(child.settingStyle(.hardware).style, .hardware)
        let root = ThemeDefinition(id: "r", name: "R", baseAppearance: .dark, style: .sticker)
        XCTAssertNil(root.settingStyle(.hardware).style)
        XCTAssertEqual(root.settingStyle(.softBlocks).style, .softBlocks)
    }

    func testRadiusScales() {
        XCTAssertEqual(InterfaceStyle.allCases.map(\.radiusScale), [1, 1.4, 2.0, 1.35])
    }
}
