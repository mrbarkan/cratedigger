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
