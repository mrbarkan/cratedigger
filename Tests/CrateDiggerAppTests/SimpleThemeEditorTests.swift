import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The Simple editor's model: history, Shuffle's limits, the unapplied flag,
/// reopening a saved theme and the swatch-to-jobs map. Uses a temp Themes folder.
@MainActor
final class SimpleThemeEditorTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var savedSelection: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleThemeEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try ThemeAuthoringService(themesDirectory: themesDirectory).save(ThemeDefinition(
            id: "base-theme", name: "Base Theme", baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#E07020"]
        ))
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
    }

    override func tearDownWithError() throws {
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    private func newEditor() throws -> SimpleThemeEditor {
        SimpleThemeEditor(newFrom: try manifest("base-theme"), registry: registry)
    }

    func testShuffleKeepsContrastFontsMaterial() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        editor.choices.material = .brushed
        editor.choices.coverLook = .grid
        let fonts = editor.choices.fonts
        for _ in 0..<5 { editor.shuffle() }
        XCTAssertEqual(editor.history.current.contrast, .high)
        XCTAssertEqual(editor.choices.material, .brushed)
        XCTAssertEqual(editor.choices.coverLook, .grid)
        XCTAssertEqual(editor.choices.fonts, fonts)
    }

    func testBackUndoesColourEdit() throws {
        let editor = try newEditor()
        let before = editor.history.current
        editor.edit { $0.addColor("#33AA55") }
        XCTAssertEqual(editor.history.current.palette.count, before.palette.count + 1)
        editor.back()
        XCTAssertEqual(editor.history.current, before)
        editor.forward()
        XCTAssertEqual(editor.history.current.palette.count, before.palette.count + 1)
    }

    func testHistoryKeepsTwentySteps() throws {
        let editor = try newEditor()
        for _ in 0..<40 { editor.shuffle() }
        var steps = 0
        while editor.history.canGoBack { editor.back(); steps += 1 }
        XCTAssertLessThanOrEqual(steps, 19)
    }

    func testApplyWritesAndClearsUnapplied() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        XCTAssertTrue(editor.hasUnappliedChanges)
        try editor.apply()
        XCTAssertFalse(editor.hasUnappliedChanges)
        XCTAssertTrue(try manifest(editor.candidate.id).definition.isSimple)
    }

    func testCloseWithUnappliedAsks() throws {
        let editor = try newEditor()
        XCTAssertFalse(editor.hasUnappliedChanges)
        editor.edit { $0.contrast = .soft }
        XCTAssertTrue(editor.hasUnappliedChanges)
        editor.discard()
        XCTAssertFalse(editor.hasUnappliedChanges)
        XCTAssertEqual(editor.history.current.contrast, .standard)
        editor.name = "Renamed"
        XCTAssertTrue(editor.hasUnappliedChanges)
        editor.choices.material = .weave
        try editor.apply()
        XCTAssertFalse(editor.hasUnappliedChanges)
        editor.choices.material = .plastic
        XCTAssertTrue(editor.hasUnappliedChanges)
    }

    func testReopenNeedsWarningOnce() throws {
        let first = try newEditor()
        first.edit { $0.contrast = .high }
        try first.apply()
        let saved = try manifest(first.candidate.id)

        let editor = SimpleThemeEditor(reopening: saved, registry: registry)
        XCTAssertTrue(editor.isReopenedSaved)
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.candidate.colors, saved.definition.colors)
        XCTAssertFalse(editor.hasUnappliedChanges)
        // A font change applies straight onto the saved colours.
        editor.choices.fonts["mono"] = SimpleFontPresets.labels[0].font
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.candidate.colors, saved.definition.colors)
        editor.confirmRegenerate()
        XCTAssertFalse(editor.needsRegenerateWarning)
        editor.shuffle()
        XCTAssertFalse(editor.needsRegenerateWarning)
    }

    private func reopened() throws -> (SimpleThemeEditor, ThemeManifest) {
        let first = try newEditor()
        try first.apply()
        let saved = try manifest(first.candidate.id)
        return (SimpleThemeEditor(reopening: saved, registry: registry), saved)
    }

    func testFontMaterialLookDoNotRebuildColoursOnReopen() throws {
        let (editor, saved) = try reopened()
        editor.choices.fonts["mono"] = SimpleFontPresets.labels[0].font
        editor.choices.material = .brushed
        editor.choices.coverLook = .pixel
        editor.name = "Other"
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.candidate.colors, saved.definition.colors)
        XCTAssertEqual(editor.candidate.light?.colors, saved.definition.light?.colors)
        XCTAssertFalse(editor.needsWarning(for: .fonts))
        XCTAssertFalse(editor.needsWarning(for: .material))
        XCTAssertFalse(editor.needsWarning(for: .coverLook))
        XCTAssertFalse(editor.needsWarning(for: .name))
        XCTAssertTrue(editor.needsWarning(for: .appearance))
        XCTAssertTrue(editor.needsWarning(for: .shuffle))
    }

    func testAppearanceChangeIsGatedAndRebuilds() throws {
        let (editor, saved) = try reopened()
        XCTAssertTrue(editor.needsWarning(for: .appearance))
        editor.confirmRegenerate()
        editor.choices.appearance = .light
        XCTAssertNotEqual(editor.candidate.colors, saved.definition.colors)
        XCTAssertFalse(editor.needsWarning(for: .appearance))
    }

    /// A Simple theme saved while Simple themes still inherited opens on a
    /// self-contained seed: the parent's fonts carried in, no parent named,
    /// regenerated at once (no question), and APPLY ready to write it whole.
    func testLegacyInheritingSimpleThemeOpensSelfContained() throws {
        let authoring = ThemeAuthoringService(themesDirectory: themesDirectory)
        var parent = ThemeDefinition(id: "font-parent", name: "Font Parent", baseAppearance: .dark,
                                     colors: ["chassis": "#111111"])
        parent.fonts = ["mono": SimpleFontPresets.labels[0].font]
        try authoring.save(parent)
        var child = ThemeDefinition(id: "font-child", name: "Font Child", baseAppearance: .dark,
                                    inherits: "font-parent")
        child.simple = SimpleThemeRecipe(palette: ["#1E2430", "#E8E4DA"])
        try authoring.save(child)
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)), userThemesDirectoryOverride: themesDirectory))
        let editor = SimpleThemeEditor(reopening: try manifest("font-child"), registry: registry)
        XCTAssertEqual(editor.previewFonts?["mono"], parent.fonts?["mono"])
        XCTAssertNil(editor.candidate.inherits)
        XCTAssertEqual(editor.candidate.id, "font-child")
        XCTAssertFalse(editor.needsRegenerateWarning)
        XCTAssertTrue(editor.hasUnappliedChanges)
        try editor.apply()
        XCTAssertNil(try manifest("font-child").definition.inherits)
        XCTAssertEqual(try manifest("font-child").definition.fonts?["mono"], parent.fonts?["mono"])
    }

    func testPreviewStartsOnTheGivenAppearance() throws {
        let both = registry.newSimpleSeed(from: try manifest("base-theme"))
        var adaptive = both
        adaptive.light = ThemeVariant()
        adaptive.dark = ThemeVariant()
        let editor = SimpleThemeEditor(copyOf: adaptive, registry: registry, appearance: .light)
        XCTAssertEqual(editor.previewAppearance, .light)
        XCTAssertEqual(SimpleThemeEditor(copyOf: adaptive, registry: registry, appearance: .dark).previewAppearance,
                       .dark)
    }

    func testRecipeVersionIsTheCurrentTable() throws {
        let editor = try newEditor()
        XCTAssertEqual(editor.candidate.simple?.recipe, SimplePaletteRecipe.currentVersion)
        editor.shuffle()
        XCTAssertEqual(editor.candidate.simple?.recipe, SimplePaletteRecipe.currentVersion,
                       "a Shuffle is not a recipe version")
    }

    func testDiscardAfterApplyReturnsToApplied() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        try editor.apply()
        let applied = editor.candidate
        editor.edit { $0.contrast = .soft }
        editor.choices.material = .weave
        editor.discard()
        XCTAssertEqual(editor.candidate, applied)
        XCTAssertFalse(editor.hasUnappliedChanges)
    }

    func testCopyOfSimpleKeepsRecipe() throws {
        let first = try newEditor()
        first.edit { $0.contrast = .high }
        try first.apply()
        let saved = try manifest(first.candidate.id).definition
        let copy = SimpleThemeEditor(copyOf: saved, registry: registry)
        XCTAssertNil(saved.inherits)
        XCTAssertNil(copy.base.inherits)
        XCTAssertEqual(copy.history.current.recipe, saved.simple)
        XCTAssertEqual(copy.name, "\(saved.name) Copy")
        XCTAssertNotEqual(copy.base.id, saved.id)
    }

    func testCopyOfNonSimpleUsesExtractedSeed() throws {
        let original = try manifest("base-theme").definition
        let copy = SimpleThemeEditor(copyOf: original, registry: registry)
        XCTAssertNil(copy.base.inherits)
        XCTAssertEqual(copy.name, "Base Theme Copy")
        XCTAssertNotEqual(copy.history.current.palette, ["#1E2430", "#E8E4DA"])
        XCTAssertEqual(copy.history.current.recipe, registry.newSimpleSeed(copyOf: original).simple)
    }

    func testNoOpEditKeepsWarningAndHistory() throws {
        let first = try newEditor()
        try first.apply()
        let editor = SimpleThemeEditor(reopening: try manifest(first.candidate.id), registry: registry)
        editor.edit { _ in }
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertFalse(editor.history.canGoBack)
    }

    func testApplyThrowingLeavesModelUnchanged() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: themesDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: themesDirectory.path) }
        XCTAssertThrowsError(try editor.apply())
        XCTAssertTrue(editor.hasUnappliedChanges)
        XCTAssertEqual(editor.history.current.contrast, .high)
    }

    func testDraftUntouchedBeforeApply() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        editor.shuffle()
        _ = editor.previewTheme
        XCTAssertNil(registry.draft)
    }

    func testWarningForPinAndContrast() throws {
        let (editor, _) = try reopened()
        XCTAssertTrue(editor.needsWarning(for: .pin))
        XCTAssertTrue(editor.needsWarning(for: .contrast))
    }

    func testBackToOpeningStateClearsUnapplied() throws {
        let editor = try newEditor()
        editor.edit { $0.contrast = .high }
        XCTAssertTrue(editor.hasUnappliedChanges)
        editor.back()
        XCTAssertFalse(editor.hasUnappliedChanges)
    }

    func testHighlightDoesNotRebuildCandidate() throws {
        let editor = try newEditor()
        let a = editor.previewTheme.theme
        editor.highlightedJobs = [.accent]
        XCTAssertEqual(editor.previewTheme.theme.id, a.id)
        XCTAssertFalse(editor.hasUnappliedChanges)
    }

    func testExtractedAssignmentSurvivesContrastAndSetColor() throws {
        let editor = try newEditor()
        let assignment = editor.history.current.assignment
        editor.edit { $0.contrast = .high }
        XCTAssertEqual(editor.history.current.assignment, assignment)
        editor.edit { $0.setColor("#445566", at: 0) }
        XCTAssertEqual(editor.history.current.assignment, assignment)
    }

    func testRemovalThatBreaksAssignmentRepicks() throws {
        let editor = try newEditor()
        editor.edit { $0.addColor("#33AA55"); $0.addColor("#AA3355") }
        let count = editor.history.current.palette.count
        let before = editor.history.current.assignment
        editor.edit { $0.removeColor(at: 0) }
        XCTAssertNotEqual(editor.history.current.assignment, before)
        let state = editor.history.current
        XCTAssertEqual(state.palette.count, count - 1)
        XCTAssertTrue(SimplePaletteAssigner.isStructurallyValid(
            state.assignment, paletteCount: state.palette.count, pins: state.pins))
    }

    func testPinMovesOnlyThatJob() throws {
        let editor = try newEditor()
        let before = editor.history.current.assignment
        let target = ((before[.frame] ?? nil) ?? 0) == 0 ? 1 : 0
        editor.edit { $0.pin(.frame, to: target) }
        let after = editor.history.current.assignment
        for job in ThemeJob.allCases where job != .frame { XCTAssertEqual(after[job] ?? nil, before[job] ?? nil) }
        XCTAssertEqual(after[.frame] ?? nil, target)
    }

    func testJobsForSwatch() throws {
        let editor = try newEditor()
        let state = editor.history.current
        var seen = Set<ThemeJob>()
        for index in state.palette.indices {
            let jobs = editor.jobs(forSwatch: index)
            for job in jobs { XCTAssertEqual(state.assignment[job] ?? nil, index) }
            seen.formUnion(jobs)
        }
        let assigned = Set(ThemeJob.allCases.filter { (state.assignment[$0] ?? nil) != nil })
        XCTAssertEqual(seen, assigned)
        XCTAssertTrue(editor.jobs(forSwatch: 99).isEmpty)
    }
}
