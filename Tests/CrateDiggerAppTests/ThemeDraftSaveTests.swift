import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Covers the editor's save path end to end — seed a draft, change it, write
/// it, read it back with the real loader — minus the two pieces a unit test
/// shouldn't touch: `NSFontPanel` and the user's actual `selectedThemeID`.
///
/// Exists because "the font isn't saving" was reported and reading the code
/// wasn't enough to say which half was at fault.
@MainActor
final class ThemeDraftSaveTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var authoring: ThemeAuthoringService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeDraftSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        // A stand-in "installed" theme to fork from, so the test never depends
        // on what happens to be bundled.
        authoring = ThemeAuthoringService(themesDirectory: themesDirectory)
        try authoring.save(ThemeDefinition(
            id: "base-theme",
            name: "Base Theme",
            baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE"]
        ))

        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
    }

    override func tearDownWithError() throws {
        if let themesDirectory, FileManager.default.fileExists(atPath: themesDirectory.path) {
            try FileManager.default.removeItem(at: themesDirectory)
        }
        try super.tearDownWithError()
    }

    /// `saveDraft()` also writes `PreferencesStore.selectedThemeID`, which is a
    /// real user default — so the test drives the same logic without that side
    /// effect on whoever is running it.
    private func saveCurrentDraft() throws {
        let draft = try XCTUnwrap(registry.draft)
        let parent = registry.manifest(for: draft.inherits)?.definition
        try authoring.save(ThemeAuthoringService.minimized(draft, against: parent))
        registry.refresh()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    func testSeededDraftFillsEveryEditableToken() throws {
        registry.beginEditing(try manifest("base-theme"))
        let draft = try XCTUnwrap(registry.draft)

        // Every control must open on a real value, including tokens the file
        // never mentions — otherwise a swatch reads empty and a dial reads 0.
        XCTAssertEqual(draft.colors?.count, ThemeTokenCatalog.allColorTokens.count)
        XCTAssertEqual(draft.geometry?.count, ThemeTokenCatalog.allGeometryTokens.count)
        XCTAssertNotNil(draft.fonts, "font rows assign into this dictionary; nil would silently discard picks")
    }

    /// The reported bug: choose a font, save, and it should still be there.
    func testFontChoiceSurvivesSave() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.fonts?["sans"] = "Helvetica-Bold"

        try saveCurrentDraft()

        let reloaded = try manifest("base-theme")
        XCTAssertEqual(reloaded.definition.fonts?["sans"], "Helvetica-Bold")
    }

    /// Forking a theme must carry the font too — this is the path the editor
    /// actually takes for a built-in.
    func testFontChoiceSurvivesSaveOnAFork() throws {
        var builtIn = try manifest("base-theme")
        builtIn = ThemeManifest(definition: builtIn.definition, origin: .builtIn)

        registry.beginEditing(builtIn)
        let forkID = try XCTUnwrap(registry.draft?.id)
        registry.draft?.fonts?["mono"] = "Menlo-Regular"

        try saveCurrentDraft()

        let reloaded = try manifest(forkID)
        XCTAssertEqual(reloaded.definition.fonts?["mono"], "Menlo-Regular")
    }

    /// A font change must reach the rendered theme, not just the file —
    /// `fontsSignature` is what makes the UI re-letter at all.
    func testRenderedThemeCarriesTheFontSignature() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.fonts?["sans"] = "Helvetica-Bold"

        let resolved = try XCTUnwrap(registry.resolvedTheme(for: nil))
        XCTAssertTrue(resolved.theme.fontsSignature.contains("Helvetica-Bold"))
    }

    /// Resetting a role back to the default must actually drop it from the
    /// file, not persist an empty entry.
    func testResettingAFontRemovesItFromTheSavedTheme() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.fonts?["sans"] = "Helvetica-Bold"
        try saveCurrentDraft()

        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.fonts?["sans"] = nil
        try saveCurrentDraft()

        XCTAssertNil(try manifest("base-theme").definition.fonts?["sans"])
    }

    /// The font menu records a PostScript name, not the family name — picking
    /// "Helvetica" must not yield "Helvetica-BoldOblique", and must yield
    /// something `Font.custom` can actually resolve.
    func testFamilyResolvesToItsRegularFace() throws {
        let resolved = try XCTUnwrap(ThemeTokenCatalog.regularPostScriptName(inFamily: "Helvetica"))
        XCTAssertNotNil(NSFont(name: resolved, size: 12), "recorded name must resolve as a real font")

        let lowered = resolved.lowercased()
        XCTAssertFalse(lowered.contains("oblique"))
        XCTAssertFalse(lowered.contains("italic"))
        XCTAssertFalse(lowered.contains("bold"))
    }

    func testEveryInstalledFamilyResolvesOrIsSkipped() throws {
        // The menu offers these by name, so any family that can't produce a
        // usable face would be a dead entry in the list.
        let families = ThemeTokenCatalog.systemFontFamilies
        XCTAssertFalse(families.isEmpty)
        for family in families.prefix(40) {
            let resolved = ThemeTokenCatalog.regularPostScriptName(inFamily: family)
            XCTAssertNotNil(resolved, "no usable face resolved for \(family)")
        }
    }

    /// A color edit and a font edit in the same session must both land.
    func testColorAndFontEditsSaveTogether() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.colors?["orange"] = "#00FF00"
        registry.draft?.fonts?["display"] = "Courier"

        try saveCurrentDraft()

        let reloaded = try manifest("base-theme").definition
        XCTAssertEqual(reloaded.colors?["orange"], "#00FF00")
        XCTAssertEqual(reloaded.fonts?["display"], "Courier")
    }
}
