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

    /// Exercises the real `saveDraft()` rather than a replica of it — the
    /// earlier tests here rebuilt its logic to dodge the `selectedThemeID`
    /// write, which meant the shipping method itself was never run.
    func testSaveDraftWritesFontsToDisk() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.fonts?["display"] = "SFProDisplay-Regular"

        let savedID = try registry.saveDraft()
        XCTAssertEqual(savedID, "base-theme")

        // Read the file itself: whatever the in-memory registry believes, the
        // JSON on disk is what survives a relaunch.
        let onDisk = themesDirectory
            .appendingPathComponent("base-theme.cdtheme")
            .appendingPathComponent("theme.json")
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: onDisk))
        XCTAssertEqual(decoded.fonts?["display"], "SFProDisplay-Regular")

        XCTAssertNil(registry.draft, "a successful save should close out the draft")
        XCTAssertEqual(
            registry.manifest(for: "base-theme")?.definition.fonts?["display"],
            "SFProDisplay-Regular"
        )
    }

    /// The real-world failure: a hand-authored theme whose *folder* is named
    /// for its display name while its `id` is a slug. Saving must rewrite that
    /// file, not create `<id>.cdtheme` beside it — two files sharing an id make
    /// the loader drop one, and it drops whichever sorts later, so the edit
    /// disappears despite having been written successfully.
    func testSavingAThemeWhoseFolderNameDiffersFromItsIDRewritesTheOriginal() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        // "Apple Music.cdtheme" containing { "id": "apple-music" }.
        let prettyFolder = themesDirectory.appendingPathComponent("Apple Music.cdtheme", isDirectory: true)
        try FileManager.default.createDirectory(at: prettyFolder, withIntermediateDirectories: true)
        let prettyManifest = prettyFolder.appendingPathComponent("theme.json")
        try JSONEncoder().encode(ThemeDefinition(
            id: "apple-music",
            name: "Apple Music",
            baseAppearance: .dark,
            colors: ["chassis": "#222222"]
        )).write(to: prettyManifest)

        registry.refresh()
        registry.beginEditing(try manifest("apple-music"))
        registry.draft?.fonts?["display"] = "SFProDisplay-Regular"
        try registry.saveDraft()

        // The original file carries the edit...
        let rewritten = try JSONDecoder().decode(
            ThemeDefinition.self,
            from: Data(contentsOf: prettyManifest)
        )
        XCTAssertEqual(rewritten.fonts?["display"], "SFProDisplay-Regular")

        // ...and no shadow copy was created to compete with it.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: themesDirectory.appendingPathComponent("apple-music.cdtheme").path),
            "saving must not create a second file sharing this theme's id"
        )

        // Which means the loader still surfaces exactly one, with the edit.
        XCTAssertEqual(registry.manifests.filter { $0.id == "apple-music" }.count, 1)
        XCTAssertEqual(try manifest("apple-music").definition.fonts?["display"], "SFProDisplay-Regular")
        XCTAssertTrue(registry.loadWarnings.isEmpty, "a clean folder should produce no duplicate-id warnings")
    }

    /// The LIGHT/DARK keys write `baseAppearance`, which decides window chrome
    /// and which built-in fills tokens the theme omits.
    func testBaseAppearanceFlipSurvivesSave() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        registry.beginEditing(try manifest("base-theme"))
        XCTAssertEqual(registry.draft?.baseAppearance, .dark)

        registry.draft?.baseAppearance = .light
        try registry.saveDraft()

        XCTAssertEqual(try manifest("base-theme").definition.baseAppearance, .light)
        XCTAssertFalse(try XCTUnwrap(registry.resolvedTheme(for: "base-theme")).theme.isDark)
    }

    /// Flipping to light must actually produce a light theme. Seeding fills
    /// every token from the *old* rendering, so without re-seeding the flip
    /// changes a flag and nothing else — the palette stays dark and the key
    /// looks broken.
    func testBaseAppearanceFlipRepaintsUntouchedColors() throws {
        registry.beginEditing(try manifest("base-theme"))
        let darkInk = registry.draft?.colors?["ink"]

        registry.setDraftBaseAppearance(.light)

        XCTAssertNotEqual(registry.draft?.colors?["ink"], darkInk,
                          "untouched tokens should follow the new base appearance")
        XCTAssertEqual(registry.draft?.colors?["ink"], CarbonTheme.linen.ink.themeHexString)

        // Reversible: going back restores the theme's own palette rather than
        // dumping it into the generic dark built-in.
        registry.setDraftBaseAppearance(.dark)
        XCTAssertEqual(registry.draft?.colors?["ink"], darkInk)
    }

    /// ...but an edit you actually made must survive the flip.
    func testBaseAppearanceFlipKeepsEditedColors() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.draft?.colors?["orange"] = "#00FF00"

        registry.setDraftBaseAppearance(.light)

        XCTAssertEqual(registry.draft?.colors?["orange"], "#00FF00")
    }

    // MARK: - Adaptive (light + dark in one theme)

    /// Switching a dark theme to BOTH must produce a usable light version
    /// immediately, without disturbing the dark one.
    func testGoingAdaptiveBuildsTheOppositeLayer() throws {
        registry.beginEditing(try manifest("base-theme"))
        let darkInk = registry.draftColor("ink")

        registry.setDraftAdaptive(true)

        XCTAssertTrue(try XCTUnwrap(registry.draft).isAdaptive)
        XCTAssertEqual(registry.draftEditingAppearance, .dark)
        XCTAssertEqual(registry.draftColor("ink"), darkInk, "the original appearance is untouched")

        registry.draftEditingAppearance = .light
        XCTAssertEqual(registry.draftColor("ink"), CarbonTheme.linen.ink.themeHexString)
    }

    /// The whole point of layers: a color changed in Light must not change Dark.
    func testEditingOneLayerLeavesTheOtherAlone() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)

        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")

        XCTAssertEqual(registry.draftColor("orange"), "#00FF00")
        registry.draftEditingAppearance = .dark
        XCTAssertNotEqual(registry.draftColor("orange"), "#00FF00")
    }

    func testAdaptiveThemeSurvivesSaveAndRendersBothWays() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)
        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")
        try registry.saveDraft()

        let reloaded = try manifest("base-theme").definition
        XCTAssertTrue(reloaded.isAdaptive)

        // One theme, two looks — chosen by the appearance asked for.
        let light = try XCTUnwrap(registry.resolvedTheme(for: "base-theme", appearance: .light))
        let dark = try XCTUnwrap(registry.resolvedTheme(for: "base-theme", appearance: .dark))
        XCTAssertFalse(light.theme.isDark)
        XCTAssertTrue(dark.theme.isDark)
        XCTAssertNotEqual(light.theme.orange, dark.theme.orange)
    }

    /// A single-appearance theme must keep ignoring the requested appearance,
    /// or every existing skin would start following the system.
    func testNonAdaptiveThemeStillForcesItsOwnAppearance() throws {
        let light = try XCTUnwrap(registry.resolvedTheme(for: "base-theme", appearance: .light))
        XCTAssertTrue(light.theme.isDark, "a dark-only theme stays dark even when light is requested")
    }

    func testCollapsingBackToOneAppearanceKeepsWhatWasOnScreen() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)
        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")

        registry.setDraftAdaptive(false)

        XCTAssertFalse(try XCTUnwrap(registry.draft).isAdaptive)
        XCTAssertEqual(registry.draft?.baseAppearance, .light)
        XCTAssertEqual(registry.draftColor("orange"), "#00FF00")
    }

    // MARK: - Copying one layer onto the other

    func testCopyingALayerMakesTheOtherMatch() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)

        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")
        registry.setDraftColor("ink", "#010203")
        registry.copyDraftLayer(to: .dark)

        registry.draftEditingAppearance = .dark
        XCTAssertEqual(registry.draftColor("orange"), "#00FF00")
        XCTAssertEqual(registry.draftColor("ink"), "#010203")
    }

    /// Copying must not disturb the layer it copied from.
    func testCopyingALayerLeavesTheSourceIntact() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)
        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")

        registry.copyDraftLayer(to: .dark)

        XCTAssertEqual(registry.draftEditingAppearance, .light)
        XCTAssertEqual(registry.draftColor("orange"), "#00FF00")
    }

    /// It copies what you can *see* — resolved values, including tokens the
    /// layer never overrode and inherits from the shared set.
    func testCopyingCarriesSharedTokensNotJustOverrides() throws {
        registry.beginEditing(try manifest("base-theme"))
        let sharedInk = registry.draftColor("ink")
        registry.setDraftAdaptive(true)

        // Light starts repainted from the light built-in; copy it onto dark.
        registry.draftEditingAppearance = .light
        let lightInk = registry.draftColor("ink")
        XCTAssertNotEqual(lightInk, sharedInk)
        registry.copyDraftLayer(to: .dark)

        registry.draftEditingAppearance = .dark
        XCTAssertEqual(registry.draftColor("ink"), lightInk)
    }

    func testCopiedLayerSurvivesSave() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftAdaptive(true)
        registry.draftEditingAppearance = .light
        registry.setDraftColor("orange", "#00FF00")
        registry.copyDraftLayer(to: .dark)
        try registry.saveDraft()

        let light = try XCTUnwrap(registry.resolvedTheme(for: "base-theme", appearance: .light))
        let dark = try XCTUnwrap(registry.resolvedTheme(for: "base-theme", appearance: .dark))
        XCTAssertEqual(light.theme.orange, dark.theme.orange)
        // Still two distinct appearances, just with a shared accent.
        XCTAssertFalse(light.theme.isDark)
        XCTAssertTrue(dark.theme.isDark)
    }

    /// Nothing to copy between when the theme has only one appearance.
    func testCopyingIsANoOpOnASingleAppearanceTheme() throws {
        registry.beginEditing(try manifest("base-theme"))
        let before = registry.draft

        registry.copyDraftLayer(to: .light)

        XCTAssertEqual(registry.draft, before)
    }

    // MARK: - Duplicate

    func testDuplicateForksTheDraftWithoutTouchingTheOriginal() throws {
        let previousSelection = PreferencesStore.shared.selectedThemeID
        defer { PreferencesStore.shared.selectedThemeID = previousSelection }

        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftColor("orange", "#00FF00")
        registry.duplicateDraft()

        XCTAssertNotEqual(registry.draft?.id, "base-theme")
        XCTAssertEqual(registry.draft?.name, "Base Theme Copy")
        XCTAssertEqual(registry.draftColor("orange"), "#00FF00", "edits carry into the copy")

        try registry.saveDraft()

        // Original untouched, copy added alongside it.
        XCTAssertNotEqual(try manifest("base-theme").definition.colors?["orange"], "#00FF00")
        XCTAssertEqual(registry.manifests.count, 2)
    }

    func testDuplicateNeverCollidesWithAnExistingID() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.duplicateDraft()
        let firstID = try XCTUnwrap(registry.draft?.id)
        try registry.saveDraft()

        registry.beginEditing(try manifest("base-theme"))
        registry.duplicateDraft()

        XCTAssertNotEqual(registry.draft?.id, firstID)
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
