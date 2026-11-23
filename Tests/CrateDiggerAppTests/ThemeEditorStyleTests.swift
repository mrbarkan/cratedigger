import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Choosing a theme's interface style in the editors: Advanced writes it into
/// the draft as one undo step and leaves the FLAT switch's stored value alone;
/// Simple reads it from the theme it opens and carries it into the candidate,
/// reopened or new. Uses a temp Themes folder and puts `selectedThemeID` back.
@MainActor
final class ThemeEditorStyleTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var session: ThemeEditorSession!
    private var savedSelection: String?
    private var originalWindow: TimeInterval!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        originalWindow = ThemeRegistry.undoCoalesceWindow
        // Each edit below is its own step; nothing here is a drag.
        ThemeRegistry.undoCoalesceWindow = 0
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeEditorStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let authoring = ThemeAuthoringService(themesDirectory: themesDirectory)
        try authoring.save(ThemeDefinition(
            id: "base-theme", name: "Base Theme", baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#E07020"]
        ))
        // Funhouse-like: a theme that wears Sticker.
        try authoring.save(ThemeDefinition(
            id: "sticker-theme", name: "Sticker Theme", baseAppearance: .light,
            colors: ["chassis": "#F4E9D8", "ink": "#2A2140", "orange": "#E0457B"],
            style: .sticker
        ))
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
        session = ThemeEditorSession(registry: registry)
    }

    override func tearDownWithError() throws {
        ThemeRegistry.undoCoalesceWindow = originalWindow
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    // MARK: Advanced

    func testSettingStyleOnTheDraftIsOneUndoStep() throws {
        session.open(try manifest("base-theme"))
        XCTAssertNil(session.simple, "a theme with no Simple block opens in Advanced")
        XCTAssertEqual(registry.draft?.resolvedStyle, .hardware)
        XCTAssertEqual(registry.undoDepth, 0)

        registry.setDraftStyle(.sticker)
        XCTAssertEqual(registry.draft?.resolvedStyle, .sticker)
        XCTAssertEqual(registry.undoDepth, 1, "a style is one step")

        registry.undoDraftStep()
        XCTAssertEqual(registry.draft?.resolvedStyle, .hardware)
        XCTAssertEqual(registry.undoDepth, 0)
    }

    func testStyleChangeLeavesTheFlatSwitchAsItWas() throws {
        session.open(try manifest("base-theme"))
        registry.draft?.effects = ["flat": 1]
        registry.setDraftStyle(.softBlocks)
        XCTAssertEqual(registry.draft?.effects?["flat"], 1)
        registry.setDraftStyle(.hardware)
        XCTAssertEqual(registry.draft?.effects?["flat"], 1, "FLAT works again back on Real Hardware")
        XCTAssertNil(registry.draft?.style, "Real Hardware is written as absent on a theme with no parent")
    }

    func testDiscardingTheDraftDropsTheChosenStyle() throws {
        session.open(try manifest("sticker-theme"))
        registry.setDraftStyle(.flatHardware)
        XCTAssertEqual(registry.activeDefinition(for: "sticker-theme")?.resolvedStyle, .flatHardware)
        registry.discardDraft()
        XCTAssertEqual(registry.activeDefinition(for: "sticker-theme")?.resolvedStyle, .sticker,
                       "the console goes back to the saved theme's style")
    }

    // MARK: Simple

    func testSimpleChoicesReadTheThemesStyle() throws {
        let editor = SimpleThemeEditor(copyOf: try manifest("sticker-theme").definition, registry: registry)
        XCTAssertEqual(editor.choices.style, .sticker)
        XCTAssertEqual(editor.candidate.resolvedStyle, .sticker)

        let fromNew = SimpleThemeEditor(newFrom: try manifest("sticker-theme"), registry: registry)
        XCTAssertEqual(fromNew.choices.style, .sticker)
        XCTAssertEqual(fromNew.candidate.resolvedStyle, .sticker)
    }

    func testSimpleStyleChoiceReachesTheCandidateAndDiscardPutsItBack() throws {
        let editor = SimpleThemeEditor(newFrom: try manifest("base-theme"), registry: registry)
        XCTAssertEqual(editor.choices.style, .hardware)
        editor.choices.style = .softBlocks
        XCTAssertEqual(editor.candidate.resolvedStyle, .softBlocks)
        XCTAssertTrue(editor.hasUnappliedChanges)
        editor.discard()
        XCTAssertEqual(editor.choices.style, .hardware)
        XCTAssertEqual(editor.candidate.resolvedStyle, .hardware)
    }

    /// A reopened Simple theme draws its saved colours until the first
    /// regenerating change; a style, like a material, applies straight onto them.
    func testReopenedSimpleThemeKeepsAndChangesItsStyleWithoutRegenerating() throws {
        let first = SimpleThemeEditor(newFrom: try manifest("base-theme"), registry: registry)
        first.choices.style = .sticker
        try first.apply()
        let saved = try manifest(first.candidate.id)
        XCTAssertEqual(saved.definition.resolvedStyle, .sticker)

        let editor = SimpleThemeEditor(reopening: saved, registry: registry)
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.choices.style, .sticker)
        XCTAssertEqual(editor.candidate.resolvedStyle, .sticker)
        XCTAssertFalse(editor.hasUnappliedChanges)

        XCTAssertFalse(editor.needsWarning(for: .style))
        editor.choices.style = .flatHardware
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.candidate.resolvedStyle, .flatHardware)
        XCTAssertEqual(editor.candidate.colors, saved.definition.colors)
        XCTAssertTrue(editor.hasUnappliedChanges)
    }
}
