#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ThemeLoaderServiceTests: XCTestCase {
    func testDiscoversBareJSONAndCdthemeBundledThemes() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeThemeJSON(named: "linen.json", in: themesDirectory, id: "linen", name: "Linen", baseAppearance: "light")
            try writeCdtheme(named: "Carbon.cdtheme", in: themesDirectory, id: "carbon", name: "Carbon", baseAppearance: "dark")

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)

            let result = loader.discoverThemes()

            XCTAssertEqual(Set(result.themes.map(\.id)), ["linen", "carbon"])
            XCTAssertTrue(result.warnings.isEmpty)
            XCTAssertTrue(result.themes.allSatisfy { $0.origin == .builtIn })
        }
    }

    func testUserThemesFolderIsCreatedAndDiscovered() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: userThemesDirectory.path))

            try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            try writeCdtheme(named: "SunsetVinyl.cdtheme", in: userThemesDirectory, id: "sunset-vinyl", name: "Sunset Vinyl", baseAppearance: "dark")

            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            XCTAssertEqual(result.themes.count, 1)
            XCTAssertEqual(result.themes.first?.id, "sunset-vinyl")
            if case .userInstalled(let sourceURL) = result.themes.first?.origin {
                XCTAssertEqual(sourceURL.lastPathComponent, "theme.json")
            } else {
                XCTFail("Expected userInstalled origin")
            }
        }
    }

    func testAutoCreatesMissingUserThemesFolder() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let userThemesDirectory = temporaryDirectory.appendingPathComponent("DoesNotExistYet", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)

            _ = loader.discoverThemes()

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: userThemesDirectory.path, isDirectory: &isDirectory)
            XCTAssertTrue(exists && isDirectory.boolValue)
        }
    }

    func testMalformedThemeFileProducesWarningNotCrash() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeThemeJSON(named: "good.json", in: themesDirectory, id: "good", name: "Good", baseAppearance: "light")
            try Data("{ not valid json".utf8).write(to: themesDirectory.appendingPathComponent("broken.json"))

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            XCTAssertEqual(result.themes.map(\.id), ["good"])
            XCTAssertEqual(result.warnings.count, 1)
            XCTAssertEqual(result.warnings.first?.sourceURL.lastPathComponent, "broken.json")
        }
    }

    func testDuplicateThemeIdIsIgnoredWithWarning() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeThemeJSON(named: "a.json", in: themesDirectory, id: "dup", name: "First", baseAppearance: "light")
            try writeThemeJSON(named: "b.json", in: themesDirectory, id: "dup", name: "Second", baseAppearance: "light")

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            XCTAssertEqual(result.themes.count, 1)
            XCTAssertEqual(result.themes.first?.definition.name, "First")
            XCTAssertEqual(result.warnings.count, 1)
        }
    }

    func testMissingIdIsRejectedWithWarning() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeThemeJSON(named: "no-id.json", in: themesDirectory, id: "", name: "No Id", baseAppearance: "light")

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            XCTAssertTrue(result.themes.isEmpty)
            XCTAssertEqual(result.warnings.count, 1)
        }
    }

    func testPartialThemeInheritsMissingTokensFromBase() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeCdtheme(
                named: "Carbon.cdtheme",
                in: themesDirectory,
                id: "carbon",
                name: "Carbon",
                baseAppearance: "dark",
                colors: ["chassis": "#171C22", "orange": "#FF6D3F"],
                geometry: ["chassisCornerRadius": 10]
            )

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            try writeCdtheme(
                named: "SunsetVinyl.cdtheme",
                in: userThemesDirectory,
                id: "sunset-vinyl",
                name: "Sunset Vinyl",
                baseAppearance: "dark",
                inherits: "carbon",
                colors: ["orange": "#FF00AA"]
            )

            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            let resolved = try XCTUnwrap(result.themes.first { $0.id == "sunset-vinyl" }?.definition)
            XCTAssertEqual(resolved.colors?["orange"], "#FF00AA", "override should win")
            XCTAssertEqual(resolved.colors?["chassis"], "#171C22", "unset token should be inherited from base")
            XCTAssertEqual(resolved.geometry?["chassisCornerRadius"], 10, "geometry should also inherit")
        }
    }

    func testUnresolvableInheritsReferenceDoesNotCrashOrWarn() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeCdtheme(
                named: "Orphan.cdtheme",
                in: themesDirectory,
                id: "orphan",
                name: "Orphan",
                baseAppearance: "dark",
                inherits: "does-not-exist",
                colors: ["orange": "#FF00AA"]
            )

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            let resolved = try XCTUnwrap(result.themes.first { $0.id == "orphan" }?.definition)
            XCTAssertEqual(resolved.colors?["orange"], "#FF00AA")
            XCTAssertTrue(result.warnings.isEmpty)
        }
    }

    func testInheritsCycleIsGuardedAndWarns() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let themesDirectory = bundle.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
            try writeCdtheme(named: "A.cdtheme", in: themesDirectory, id: "a", name: "A", baseAppearance: "dark", inherits: "b", colors: ["x": "1"])
            try writeCdtheme(named: "B.cdtheme", in: themesDirectory, id: "b", name: "B", baseAppearance: "dark", inherits: "a", colors: ["y": "2"])

            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()

            let a = try XCTUnwrap(result.themes.first { $0.id == "a" }?.definition)
            let b = try XCTUnwrap(result.themes.first { $0.id == "b" }?.definition)

            XCTAssertEqual(a.colors?["x"], "1")
            XCTAssertEqual(a.colors?["y"], "2", "should still merge in the ancestor's tokens before the cycle is detected")
            XCTAssertEqual(b.colors?["x"], "1")
            XCTAssertEqual(b.colors?["y"], "2")
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testFontURLsOnlyReturnedForUserInstalledCdthemeWithFontsFolder() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerThemeLoaderTests") { temporaryDirectory in
            let bundle = try makeAppBundle(in: temporaryDirectory)
            let userThemesDirectory = temporaryDirectory.appendingPathComponent("UserThemes", isDirectory: true)
            try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)

            let cdthemeDirectory = userThemesDirectory.appendingPathComponent("Retro.cdtheme", isDirectory: true)
            try writeCdtheme(named: "Retro.cdtheme", in: userThemesDirectory, id: "retro", name: "Retro", baseAppearance: "dark")
            let fontsDirectory = cdthemeDirectory.appendingPathComponent("Fonts", isDirectory: true)
            try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
            try Data("fake-font".utf8).write(to: fontsDirectory.appendingPathComponent("Retro-Regular.ttf"))
            try Data("not-a-font".utf8).write(to: fontsDirectory.appendingPathComponent("readme.txt"))

            let loader = ThemeLoaderService(bundle: bundle, userThemesDirectoryOverride: userThemesDirectory)
            let result = loader.discoverThemes()
            let manifest = try XCTUnwrap(result.themes.first { $0.id == "retro" })

            let fontURLs = loader.fontURLs(for: manifest)
            XCTAssertEqual(fontURLs.map(\.lastPathComponent), ["Retro-Regular.ttf"])
        }
    }
}

// MARK: - Test fixtures

private func makeAppBundle(in directory: URL) throws -> Bundle {
    let bundleURL = directory.appendingPathComponent("TestApp.bundle", isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.cratedigger.tests.themebundle</string>
        <key>CFBundleName</key>
        <string>TestApp</string>
        <key>CFBundlePackageType</key>
        <string>BNDL</string>
    </dict>
    </plist>
    """
    try Data(infoPlist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))

    return try XCTUnwrap(Bundle(path: bundleURL.path))
}

private func writeThemeJSON(
    named fileName: String,
    in directory: URL,
    id: String,
    name: String,
    baseAppearance: String,
    inherits: String? = nil,
    colors: [String: String]? = nil,
    geometry: [String: Double]? = nil
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payload = themeJSONObject(id: id, name: name, baseAppearance: baseAppearance, inherits: inherits, colors: colors, geometry: geometry)
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    try data.write(to: directory.appendingPathComponent(fileName))
}

private func writeCdtheme(
    named folderName: String,
    in directory: URL,
    id: String,
    name: String,
    baseAppearance: String,
    inherits: String? = nil,
    colors: [String: String]? = nil,
    geometry: [String: Double]? = nil
) throws {
    let cdthemeDirectory = directory.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: cdthemeDirectory, withIntermediateDirectories: true)
    let payload = themeJSONObject(id: id, name: name, baseAppearance: baseAppearance, inherits: inherits, colors: colors, geometry: geometry)
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    try data.write(to: cdthemeDirectory.appendingPathComponent("theme.json"))
}

private func themeJSONObject(
    id: String,
    name: String,
    baseAppearance: String,
    inherits: String?,
    colors: [String: String]?,
    geometry: [String: Double]?
) -> [String: Any] {
    var payload: [String: Any] = [
        "id": id,
        "name": name,
        "baseAppearance": baseAppearance
    ]
    if let inherits { payload["inherits"] = inherits }
    if let colors { payload["colors"] = colors }
    if let geometry { payload["geometry"] = geometry }
    return payload
}
#endif
