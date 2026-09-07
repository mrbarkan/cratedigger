import XCTest
@testable import CrateDiggerCore

final class ThemeAuthoringServiceTests: XCTestCase {
    private var themesDirectory: URL!
    private var service: ThemeAuthoringService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeAuthoringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        service = ThemeAuthoringService(themesDirectory: themesDirectory)
    }

    override func tearDownWithError() throws {
        if let themesDirectory, FileManager.default.fileExists(atPath: themesDirectory.path) {
            try FileManager.default.removeItem(at: themesDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Slugs

    func testSlugKebabCasesAndStripsPunctuation() {
        XCTAssertEqual(ThemeAuthoringService.slug(from: "Llama '97"), "llama-97")
        XCTAssertEqual(ThemeAuthoringService.slug(from: "  Midnight   Blue  "), "midnight-blue")
        XCTAssertEqual(ThemeAuthoringService.slug(from: "Carbon Copy"), "carbon-copy")
    }

    /// The loader refuses to index a theme with an empty id, so a name made
    /// entirely of punctuation still has to produce something usable.
    func testSlugFallsBackWhenNameHasNoUsableCharacters() {
        XCTAssertEqual(ThemeAuthoringService.slug(from: "!!!"), "theme")
        XCTAssertEqual(ThemeAuthoringService.slug(from: ""), "theme")
    }

    func testSlugUniquifiesAgainstTakenIDs() {
        XCTAssertEqual(ThemeAuthoringService.slug(from: "Carbon", taken: ["carbon"]), "carbon-2")
        XCTAssertEqual(ThemeAuthoringService.slug(from: "Carbon", taken: ["carbon", "carbon-2"]), "carbon-3")
    }

    // MARK: - Minimization

    func testMinimizedDropsTokensMatchingTheParent() {
        let parent = definition(id: "carbon", colors: ["chassis": "#111111", "ink": "#FFFFFF"])
        let child = definition(
            id: "mine",
            inherits: "carbon",
            colors: ["chassis": "#111111", "ink": "#00FF00"]
        )

        let minimized = ThemeAuthoringService.minimized(child, against: parent)

        XCTAssertNil(minimized.colors?["chassis"], "a token equal to the parent shouldn't be re-recorded")
        XCTAssertEqual(minimized.colors?["ink"], "#00FF00")
    }

    /// Case and a redundant opaque alpha are formatting, not intent — the
    /// editor re-renders every token it seeds, and without this a round-trip
    /// with no edits would rewrite the whole file.
    func testMinimizedTreatsEquivalentHexFormsAsUnchanged() {
        let parent = definition(id: "carbon", colors: ["chassis": "#aabbcc", "ink": "#123456"])
        let child = definition(
            id: "mine",
            inherits: "carbon",
            colors: ["chassis": "#AABBCC", "ink": "#123456FF"]
        )

        let minimized = ThemeAuthoringService.minimized(child, against: parent)

        XCTAssertNil(minimized.colors, "no real change should leave no color overrides at all")
    }

    func testMinimizedKeepsTokensThatOnlyTheChildDefines() {
        let parent = definition(id: "carbon", colors: ["chassis": "#111111"])
        let child = definition(id: "mine", inherits: "carbon", colors: ["orange": "#FF6D3F"])

        let minimized = ThemeAuthoringService.minimized(child, against: parent)

        XCTAssertEqual(minimized.colors?["orange"], "#FF6D3F")
    }

    func testMinimizedPrunesGeometryAndKeepsChanges() {
        let parent = definition(id: "carbon", geometry: ["chassisCornerRadius": 10, "footerHeight": 92])
        let child = definition(
            id: "mine",
            inherits: "carbon",
            geometry: ["chassisCornerRadius": 10, "footerHeight": 120]
        )

        let minimized = ThemeAuthoringService.minimized(child, against: parent)

        XCTAssertNil(minimized.geometry?["chassisCornerRadius"])
        XCTAssertEqual(minimized.geometry?["footerHeight"], 120)
    }

    /// A root theme has nothing to fall back on, so nothing may be pruned.
    func testMinimizedAgainstNoParentIsUntouched() {
        let root = definition(id: "mine", colors: ["chassis": "#111111"])
        XCTAssertEqual(ThemeAuthoringService.minimized(root, against: nil), root)
    }

    // MARK: - Round trip

    /// The whole contract in one test: what the editor saves is what the
    /// loader finds and parses back, in the bundle layout it expects.
    func testSavedThemeIsDiscoverableByTheLoader() throws {
        let saved = definition(
            id: "midnight",
            name: "Midnight",
            colors: ["chassis": "#101018"],
            geometry: ["chassisCornerRadius": 4]
        )
        try service.save(saved)

        let manifestURL = themesDirectory
            .appendingPathComponent("midnight.cdtheme")
            .appendingPathComponent("theme.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        let loader = ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        )
        let result = loader.discoverThemes()

        let found = try XCTUnwrap(result.themes.first { $0.id == "midnight" })
        XCTAssertEqual(found.definition.name, "Midnight")
        XCTAssertEqual(found.definition.colors?["chassis"], "#101018")
        XCTAssertEqual(found.definition.geometry?["chassisCornerRadius"], 4)
        guard case .userInstalled = found.origin else {
            return XCTFail("a theme saved to the user folder should read back as user-installed")
        }
    }

    func testSaveOverwritesTheSameThemeInPlace() throws {
        try service.save(definition(id: "midnight", name: "Midnight", colors: ["chassis": "#101018"]))
        try service.save(definition(id: "midnight", name: "Midnight II", colors: ["chassis": "#000000"]))

        let loader = ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        )
        let matches = loader.discoverThemes().themes.filter { $0.id == "midnight" }

        XCTAssertEqual(matches.count, 1, "editing a theme must not leave a second copy behind")
        XCTAssertEqual(matches.first?.definition.name, "Midnight II")
    }

    // MARK: - Fonts

    func testImportFontLandsInsideTheThemeBundle() throws {
        let source = themesDirectory.appendingPathComponent("Source.ttf")
        try Data("not a real font".utf8).write(to: source)

        let installed = try service.importFont(from: source, into: "midnight")

        XCTAssertEqual(
            installed.path,
            themesDirectory
                .appendingPathComponent("midnight.cdtheme")
                .appendingPathComponent("Fonts")
                .appendingPathComponent("Source.ttf").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    /// Re-importing while iterating on a theme is normal and must not throw
    /// "file exists".
    func testImportFontReplacesAnExistingFile() throws {
        let source = themesDirectory.appendingPathComponent("Source.ttf")
        try Data("first".utf8).write(to: source)
        _ = try service.importFont(from: source, into: "midnight")

        try FileManager.default.removeItem(at: source)
        try Data("second".utf8).write(to: source)
        let installed = try service.importFont(from: source, into: "midnight")

        XCTAssertEqual(try Data(contentsOf: installed), Data("second".utf8))
    }

    // MARK: - Logo

    /// One slot, `logo.<ext>`: importing again replaces whatever was there,
    /// across extensions, so a shared bundle never carries two marks.
    func testImportLogoKeepsOneFileAndRemoveClearsIt() throws {
        let png = themesDirectory.appendingPathComponent("Mark.PNG")
        try Data("png".utf8).write(to: png)

        let installed = try service.importLogo(from: png, into: "midnight")
        XCTAssertEqual(
            installed.path,
            themesDirectory.appendingPathComponent("midnight.cdtheme").appendingPathComponent("logo.png").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))

        let pdf = themesDirectory.appendingPathComponent("Mark.pdf")
        try Data("pdf".utf8).write(to: pdf)
        let replaced = try service.importLogo(from: pdf, into: "midnight")
        XCTAssertEqual(replaced.lastPathComponent, "logo.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path), "the PNG must not linger beside the PDF")

        try service.removeLogo(from: "midnight")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path))
        XCTAssertNoThrow(try service.removeLogo(from: "midnight"), "clearing twice is fine")
    }

    /// Each layer has its own slot, and touching one never disturbs the other
    /// or the shared file.
    func testLayerLogosLiveInTheirOwnSlots() throws {
        let png = themesDirectory.appendingPathComponent("Mark.png")
        try Data("png".utf8).write(to: png)

        let shared = try service.importLogo(from: png, into: "midnight")
        let light = try service.installLogo(Data("rendered".utf8), extension: "png", into: "midnight", layer: .light)
        let dark = try service.importLogo(from: png, into: "midnight", layer: .dark)

        XCTAssertEqual(shared.lastPathComponent, "logo.png")
        XCTAssertEqual(light.lastPathComponent, "logo-light.png")
        XCTAssertEqual(dark.lastPathComponent, "logo-dark.png")
        XCTAssertEqual(try Data(contentsOf: light), Data("rendered".utf8))

        try service.removeLogo(from: "midnight", layer: .light)
        XCTAssertFalse(FileManager.default.fileExists(atPath: light.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dark.path))
    }

    func testImportLogoRefusesABareJSONTheme() throws {
        let bare = themesDirectory.appendingPathComponent("bare.json")
        try Data("{}".utf8).write(to: bare)
        let png = themesDirectory.appendingPathComponent("Mark.png")
        try Data("png".utf8).write(to: png)

        XCTAssertThrowsError(try service.importLogo(from: png, into: "bare", replacing: bare)) { error in
            XCTAssertTrue(error is ThemeAuthoringService.LogoImportUnsupported)
        }
    }

    func testDeleteRemovesTheBundleAndIsSafeWhenMissing() throws {
        try service.save(definition(id: "midnight"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.bundleURL(for: "midnight").path))

        try service.delete(themeID: "midnight")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.bundleURL(for: "midnight").path))

        XCTAssertNoThrow(try service.delete(themeID: "midnight"))
    }

    // MARK: - Helpers

    private func definition(
        id: String,
        name: String? = nil,
        inherits: String? = nil,
        colors: [String: String]? = nil,
        geometry: [String: Double]? = nil
    ) -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            name: name ?? id.capitalized,
            baseAppearance: .dark,
            inherits: inherits,
            colors: colors,
            geometry: geometry
        )
    }
}
